// INPUT: Authenticated local courier requests and an isolated CourierEngine.
// OUTPUT: Versioned task management, single-host dispatch permissions, redacted change summaries.
// POS: Service actor boundary. Desktop UI operations never run here; see native/README.md.
import Foundation
import Darwin
import AppKit
import CourierCore
import RuneCore
import CoreFoundation

private func wholeNumber(_ value:Any?,min:Double=0) -> Double? {
    guard let number=value as? NSNumber,CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    let result=number.doubleValue
    guard result.isFinite,result>=min,result<=9_007_199_254_740_991,result.rounded()==result else { return nil }
    return result
}

extension ServiceCoordinator {
    func refreshCourierHostLiveness() {
        guard let courier,courierFailure==nil else { return }
        let snapshot=courier.snapshot()
        guard snapshot.hostAvailable,let host=snapshot.host,
              kill(host.processID,0) != 0,errno==ESRCH else { return }
        do { try courier.hostDisconnected(brokerSession:host.brokerSession) }
        catch { courierFailure="courier-persistence-failed" }
    }
    func courierSummary() -> JSONObject {
        refreshCourierHostLiveness()
        guard let courier else {
            return ["courierProtocol":1,"revision":0,"enabled":false,"hostAvailable":false,
                    "pendingCount":0,"unknownCount":0,"error":courierFailure ?? "courier-unavailable"]
        }
        let snapshot=courier.snapshot()
        var result:JSONObject=[
            "courierProtocol":snapshot.courierProtocol,"revision":snapshot.revision,
            "enabled":snapshot.enabled,"serviceEpoch":snapshot.serviceEpoch,
            "hostAvailable":snapshot.hostAvailable,
            "pendingCount":snapshot.runs.filter { [.scheduled,.preparing,.dispatching].contains($0.status) }.count,
            "unknownCount":snapshot.runs.filter(\.unresolvedUnknown).count,
            "nextActionAt":snapshot.nextActionAt ?? NSNull()
        ]
        if let courierFailure { result["error"]=courierFailure }
        return result
    }

    public func courierRequest(method:String,path:String,object:JSONObject) async throws -> JSONObject {
        guard !closingForCourier else { throw CourierError("service-stopping",httpStatus:503) }
        guard let courier, courierFailure == nil else {
            throw CourierError(courierFailure ?? "courier-unavailable",httpStatus:503)
        }
        func decode<T:Decodable>(_ type:T.Type) throws -> T {
            do { return try JSONDecoder().decode(type,from:JSONSerialization.data(withJSONObject:object)) }
            catch { throw CourierError("courier-invalid-request",httpStatus:400) }
        }
        func revision() throws -> Int {
            guard let value=wholeNumber(object["expectedRevision"],min:0), value<=Double(Int.max) else {
                throw CourierError("courier-revision-required",httpStatus:400)
            }
            return Int(value)
        }
        func boolean(_ key:String) throws -> Bool {
            guard let value=object[key] as? NSNumber,CFGetTypeID(value)==CFBooleanGetTypeID() else {
                throw CourierError("courier-invalid-request",httpStatus:400)
            }
            return value.boolValue
        }
        let parts=path.split(separator:"/").map(String.init)
        var response:JSONObject?
        switch (method,path) {
        case ("GET","/api/courier/status"),("GET","/api/courier/tasks"),("GET","/api/courier/runs"):
            return try Self.courierJSON(courier.snapshot())
        case ("POST","/api/courier/tasks"):
            _=try courier.create(decode(CourierTaskDraft.self))
        case ("PATCH","/api/courier/settings"):
            try courier.setEnabled(boolean("enabled"))
        case ("POST","/api/courier/host/register"):
            let request=try decode(CourierHostRegistration.self)
            let stopped=courier.snapshot().host.map(Self.courierProcessStopped) ?? true
            response=try Self.courierJSON(courier.registerHost(request,previousHostStopped:stopped))
        case ("POST","/api/courier/host/unregister"):
            guard let session=object["brokerSession"] as? String else { throw CourierError("courier-invalid-request",httpStatus:400) }
            try courier.unregisterHost(brokerSession:session,gateStopped:object["gateStopped"] as? Bool ?? false)
        case ("POST","/api/courier/claim"):
            let claim=try courier.claim(decode(CourierClaimRequest.self))
            response=["claim":try claim.map(Self.courierJSON) ?? NSNull()]
        case ("POST","/api/courier/begin-input"):
            let input=try decode(BeginInput.self)
            response=try Self.courierJSON(courier.beginInput(auth:input.authorization,preflight:input.preflight))
        case ("POST","/api/courier/begin-send"):
            let input=try decode(BeginSend.self)
            response=try Self.courierJSON(courier.beginSend(auth:input.authorization,target:input.target,text:input.text))
        case ("POST","/api/courier/receipt"):
            response=try Self.courierJSON(courier.receipt(decode(CourierReceiptRequest.self)))
        default:
            guard parts.count>=4, parts[0]=="api",parts[1]=="courier" else {
                throw CourierError("not-found",httpStatus:404)
            }
            if parts[2]=="tasks" {
                let id=parts[3], expected=try revision()
                if method=="PATCH",parts.count==4 {
                    _=try courier.update(id:id,expectedRevision:expected,draft:decode(CourierTaskDraft.self))
                } else if method=="DELETE",parts.count==4 {
                    try courier.delete(id:id,expectedRevision:expected)
                } else if method=="POST",parts.count==5,["pause","resume"].contains(parts[4]) {
                    _=try courier.setTaskEnabled(id:id,expectedRevision:expected,enabled:parts[4]=="resume",
                        scheduledAt:wholeNumber(object["scheduledAt"]),deadlineAt:wholeNumber(object["deadlineAt"]))
                } else if method=="POST",parts.count==5,parts[4]=="copy" {
                    guard let task=courier.snapshot().tasks.first(where:{$0.id==id}),task.revision==expected else {
                        throw CourierError("courier-revision-conflict")
                    }
                    var draft=task.draft
                    draft.enabled=false
                    // A copy is a new draft, never an implicit retry. The editor must confirm a future time.
                    draft.scheduledAt=max((Date().timeIntervalSince1970*1000+60_000).rounded(),task.scheduledAt)
                    if let supplied=wholeNumber(object["scheduledAt"]) { draft.scheduledAt=supplied }
                    draft.deadlineAt=draft.scheduledAt+CourierLimits.defaultDeliveryGraceMilliseconds
                    _=try courier.create(draft)
                } else { throw CourierError("not-found",httpStatus:404) }
            } else if parts[2]=="runs",parts.count==5,parts[4]=="confirm",method=="POST" {
                _=try courier.confirm(runID:parts[3],sent:boolean("sent"))
            } else { throw CourierError("not-found",httpStatus:404) }
        }
        let result=try response ?? Self.courierJSON(courier.snapshot())
        await courierChanged()
        return result
    }

    static func courierJSON<T:Encodable>(_ value:T) throws -> JSONObject {
        guard let object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(value)) as? JSONObject else {
            throw CourierError("courier-invalid-response",httpStatus:500)
        }
        return object
    }
    private static func courierProcessStopped(_ host:CourierHostSession) -> Bool {
        if kill(host.processID,0) != 0 { return errno == ESRCH }
        if let application=NSRunningApplication(processIdentifier:host.processID),let launched=application.launchDate {
            return abs(launched.timeIntervalSince1970*1000-host.processStartedAt)>1000
        }
        return false
    }
}

private struct BeginInput:Decodable {
    let authorization:CourierAuthorization
    let preflight:CourierPreflight
}
private struct BeginSend:Decodable {
    let authorization:CourierAuthorization
    let target:CourierTarget
    let text:String
}
