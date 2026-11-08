// INPUT: Durable service claims and explicitly selected desktop adapters.
// OUTPUT: At most one UI send attempt per permission, followed by an idempotent receipt.
// POS: Application-level delivery host, independent of panel lifetime. See native/README.md.
import Foundation
import AppKit
import CourierCore
import DesktopAutomation

@MainActor
final class CourierDeliveryHost {
    private let client:CourierServiceClient
    private let mock:Bool
    private let onSnapshot:(CourierSnapshot)->Void
    private let brokerSession=UUID().uuidString
    private let processStartedAt=((NSRunningApplication.current.launchDate ?? Date()).timeIntervalSince1970*1000).rounded()
    private var session:CourierHostSession?
    private var worker:Task<Void,Never>?
    private var adapter:(any DesktopAdapter)?
    private var pendingReceipts:[String:CourierReceiptRequest]=[:]
    private var enabled=false
    private var running=true
    private var gate=false
    private var wakeAgain=false
    private var recoveryRetry:Task<Void,Never>?

    init(client:CourierServiceClient,mock:Bool,onSnapshot:@escaping(CourierSnapshot)->Void) {
        self.client=client; self.mock=mock; self.onSnapshot=onSnapshot
    }
    func receive(_ snapshot:CourierSnapshot) {
        enabled=snapshot.enabled
        if !enabled || (session != nil && session?.serviceEpoch != snapshot.serviceEpoch) {
            gate=false; adapter?.cancel()
        }
        guard running else { return }
        if worker != nil { wakeAgain=true; return }
        worker=Task { [weak self] in await self?.drain() }
    }
    func stop() {
        running=false;gate=false;adapter?.cancel();worker?.cancel()
        recoveryRetry?.cancel()
        if worker == nil { Task { await unregister() } }
    }
    func connectionLost() { gate=false;adapter?.cancel();session=nil }
    private func drain() async {
        defer {
            worker=nil
            if !running { Task { await unregister() } }
            else if wakeAgain {
                wakeAgain=false
                worker=Task { [weak self] in await self?.drain() }
            }
        }
        do {
            // A dropped receipt is retried as a receipt, never as another UI submission.
            for (id,receipt) in pendingReceipts {
                do {
                    let _:CourierRun=try await client.request("courier/receipt",method:"POST",body:try body(receipt))
                    pendingReceipts.removeValue(forKey:id)
                } catch PanelClientError.service(let code) {
                    if ["courier-receipt-conflict","courier-receipt-stale","courier-run-not-found","courier-not-dispatched","courier-attempt-mismatch"].contains(code) {
                        // The server's persisted run remains authoritative. Never replay a click
                        // to repair a rejected receipt, and never block unrelated chats forever.
                        pendingReceipts.removeValue(forKey:id)
                    } else { throw PanelClientError.service(code) }
                }
            }
            guard running,!Task.isCancelled else { return }
            let snapshot=try await client.snapshot()
            enabled=snapshot.enabled
            if !enabled {
                gate=false
                return
            }
            if session?.serviceEpoch != snapshot.serviceEpoch || snapshot.host?.brokerSession != brokerSession {
                gate=false;adapter?.cancel()
                let registration=CourierHostRegistration(brokerSession:brokerSession,processID:ProcessInfo.processInfo.processIdentifier,
                    processStartedAt:processStartedAt,previousGateClosed:true)
                session=try await client.request("courier/host/register",method:"POST",body:try body(registration))
            }
            guard let session else { return }
            while running,enabled,!Task.isCancelled {
                let request=CourierClaimRequest(serviceEpoch:session.serviceEpoch,brokerSession:brokerSession)
                let response:ClaimResponse=try await client.request("courier/claim",method:"POST",body:try body(request))
                guard let claim=response.claim else { break }
                await deliver(claim)
                let current=try await client.snapshot()
                enabled=current.enabled
                onSnapshot(current)
                if current.serviceEpoch != session.serviceEpoch { self.session=nil;break }
            }
        } catch PanelClientError.service(let code) where code == "courier-host-recovery-wait" {
            gate=false
            recoveryRetry?.cancel()
            recoveryRetry=Task { [weak self] in
                do { try await Task.sleep(nanoseconds:5_100_000_000) } catch { return }
                guard let self,self.running else { return }
                if let snapshot=try? await self.client.snapshot() { self.receive(snapshot) }
            }
        } catch {
            gate=false;adapter?.cancel()
            // The application's event subscription reconnects with bounded backoff.
            // It will wake this host after a new epoch; old permissions are never reused.
        }
    }
    private func deliver(_ claim:CourierClaim) async {
        let run=claim.run,authorization=claim.authorization
        let target=CourierMenuModel.desktopTarget(run.target)
        let adapter=DesktopAdapters.make(agent:target.agent,mock:mock)
        self.adapter=adapter
        var sendAuthorized=false
        var request:CourierReceiptRequest
        do {
            guard running,enabled,!Task.isCancelled else { throw DesktopBlockReason.cancelled }
            let compatibility=adapter.compatibility()
            guard compatibility.canSend else { throw compatibility.blockers.first ?? DesktopBlockReason.unsupportedVersion }
            if compatibility.requiresAccessibility { try await adapter.openTarget(target) }
            let preflight=try await adapter.preflight(target)
            let cursor=String(decoding:try JSONEncoder().encode(preflight.cursor),as:UTF8.self)
            let desktopIPC = !mock && target.agent == .codex && !compatibility.requiresAccessibility
            let approval=CourierPreflight(target:run.target,messageCursor:cursor,identityVerified:true,
                composerEmpty:!desktopIPC,hostReady:true,inputMode:desktopIPC ? .desktopIPC : .composer)
            let _:CourierClaim=try await client.request("courier/begin-input",method:"POST",
                body:["authorization":try body(authorization),"preflight":try body(approval)])
            guard running,enabled,!Task.isCancelled else { throw DesktopBlockReason.cancelled }
            let staged=try await adapter.stageText(run.text,preflight:preflight)
            // Treat even a lost begin-send response conservatively as possibly authorized.
            sendAuthorized=true
            let permit:CourierSendPermit
            do {
                permit=try await client.request("courier/begin-send",method:"POST",
                    body:["authorization":try body(authorization),"target":try body(run.target),"text":run.text])
            } catch PanelClientError.service(let code) {
                sendAuthorized=false // An explicit HTTP rejection is not a lost permission reply.
                throw PanelClientError.service(code)
            }
            guard permit.authorization==authorization,permit.target==run.target,
                  permit.text.utf8.elementsEqual(run.text.utf8) else { throw DesktopBlockReason.resultUnknown }
            gate=running && enabled && !Task.isCancelled
            let desktopPermit=DesktopSendPermit(stageID:staged.stageID,expiresAt:Int64(permit.expiresAt))
            let remaining=max(0,min(5,(permit.expiresAt-Date().timeIntervalSince1970*1000)/1000))
            let monotonicExpiry=ProcessInfo.processInfo.systemUptime+remaining
            do {
                try await adapter.pressSend(staged,permit:desktopPermit,maySend:{
                    let now=Date().timeIntervalSince1970*1000
                    return self.gate && self.running && self.enabled && !Task.isCancelled
                        && ProcessInfo.processInfo.systemUptime<monotonicExpiry
                        && now>=run.scheduledAt && now<run.deadlineAt && now<permit.expiresAt
                })
            } catch let reason as DesktopBlockReason where reason != .resultUnknown {
                // Adapters classify any failure after a possible submission as resultUnknown.
                // An explicit pre-send refusal can be retried without inventing an unknown send.
                sendAuthorized=false
                throw reason
            } catch {
                // The adapter can throw after AX handled the click. Only receipt evidence can settle it.
            }
            gate=false
            let receipt=await adapter.verifyReceipt(staged)
            let verified=receipt.outcome == .sent && receipt.targetID.utf8.elementsEqual(run.target.threadID.utf8)
                && receipt.messageID.map({ !$0.isEmpty }) == true
            request=CourierReceiptRequest(authorization:authorization,outcome:verified ? .sent : .unknown,
                reason:receipt.reason?.rawValue ?? (verified ? nil : "resultUnknown"),
                targetKey:run.target.key,messageID:verified ? receipt.messageID : nil,
                evidence:verified ? "desktop-target-message" : nil)
        } catch {
            gate=false
            let reason=(error as? DesktopBlockReason)?.rawValue ?? "courier-host-interrupted"
            let retryable:Bool
            if let error=error as? DesktopBlockReason {
                retryable=[.screenLocked,.targetBusy,.userDraft,.notFrontmost,.sendUnavailable,.accessibilityRequired,.sourceUnavailable,.ownerUnavailable,.cancelled].contains(error)
            } else { retryable=false }
            request=CourierReceiptRequest(authorization:authorization,outcome:sendAuthorized ? .unknown : .definitelyNotSent,
                retryable:!sendAuthorized && retryable,reason:reason)
        }
        adapter.cancel();self.adapter=nil;gate=false
        pendingReceipts[authorization.attemptID]=request
        do {
            let _:CourierRun=try await client.request("courier/receipt",method:"POST",body:try body(request))
            pendingReceipts.removeValue(forKey:authorization.attemptID)
        } catch { /* Durable dispatching state protects against a second send after restart. */ }
    }
    private func unregister() async {
        guard let session else { return }
        let _:CourierSnapshot?=try? await client.request("courier/host/unregister",method:"POST",
            body:["brokerSession":session.brokerSession,"gateStopped":true])
        self.session=nil
    }
    private func body<T:Encodable>(_ value:T) throws -> [String:Any] {
        guard let object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(value)) as? [String:Any] else {
            throw CourierError("courier-invalid-request",httpStatus:400)
        }
        return object
    }
}

private struct ClaimResponse:Decodable { let claim:CourierClaim? }
