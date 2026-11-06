import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import RuneCore

public final class LocalHTTPServer {
    let coordinator:ServiceCoordinator, token:String, port:Int
    let group=MultiThreadedEventLoopGroup(numberOfThreads:1)
    var channel:Channel?
    var accepting=true
    var clients:[ObjectIdentifier:Channel]=[:]
    var subscribers:[ObjectIdentifier:Channel]=[:]
    public var signals:[DispatchSourceSignal]=[]
    init(coordinator:ServiceCoordinator,token:String,port:Int) { self.coordinator=coordinator; self.token=token; self.port=port }
    public func start() async throws {
        channel=try await ServerBootstrap(group:group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr),value:1)
            .serverChannelOption(ChannelOptions.backlog,value:16)
            .childChannelOption(ChannelOptions.writeBufferWaterMark,value:WriteBufferWaterMark(low:16_384,high:65_536))
            .childChannelInitializer { ch in
                self.clients[ObjectIdentifier(ch)]=ch
                return ch.pipeline.configureHTTPServerPipeline(withPipeliningAssistance:false,withErrorHandling:true).flatMap {
                    ch.pipeline.addHandler(RequestHandler(server:self))
                }
            }.bind(host:"127.0.0.1",port:port).get()
    }
    func authenticated(_ value:String?) -> Bool {
        let a=Array((value ?? "").utf8), b=Array(("Bearer "+token).utf8)
        guard a.count==b.count else { return false }
        return zip(a,b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    func encode(_ object:JSONObject) -> Data { (try? JSONSerialization.data(withJSONObject:object,options:[.sortedKeys,.withoutEscapingSlashes])) ?? Data("{}".utf8) }
    func subscribe(_ ch:Channel, view:JSONObject) {
        guard subscribers.count<16 else { ch.close(promise:nil); return }
        subscribers[ObjectIdentifier(ch)]=ch
        sendEvent(ch,view:view)
    }
    func sendEvent(_ ch:Channel,view:JSONObject) {
        guard ch.isWritable else { ch.close(promise:nil); return }
        var buf=ch.allocator.buffer(capacity:1024)
        buf.writeString("data: "); buf.writeBytes(encode(view)); buf.writeString("\n\n")
        ch.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buf)),promise:nil)
    }
    public func publish(_ view:JSONObject) {
        channel?.eventLoop.execute { for ch in self.subscribers.values { self.sendEvent(ch,view:view) } }
    }
    public func quiesce() async {
        if let channel { try? await channel.eventLoop.submit { self.accepting=false }.get() }
    }
    public func close() async {
        if let channel {
            try? await channel.eventLoop.submit { for ch in self.clients.values { ch.close(promise:nil) } }.get()
            try? await channel.close().get()
        }
        for signal in signals { signal.cancel() }
        try? await group.shutdownGracefully()
    }
}

private final class RequestHandler:ChannelInboundHandler {
    typealias InboundIn=HTTPServerRequestPart
    typealias OutboundOut=HTTPServerResponsePart
    let server:LocalHTTPServer
    var head:HTTPRequestHead?, body=Data(), handling=false, timeout:Scheduled<Void>?
    init(server:LocalHTTPServer) { self.server=server }
    func handlerAdded(context:ChannelHandlerContext) {
        timeout=context.eventLoop.scheduleTask(in:.seconds(15)) { context.close(promise:nil) }
    }
    func channelInactive(context:ChannelHandlerContext) {
        timeout?.cancel(); server.clients.removeValue(forKey:ObjectIdentifier(context.channel)); server.subscribers.removeValue(forKey:ObjectIdentifier(context.channel))
    }
    func errorCaught(context:ChannelHandlerContext,error:Error) { context.close(promise:nil) }
    func channelRead(context:ChannelHandlerContext,data:NIOAny) {
        guard !handling else { context.close(promise:nil); return }
        switch unwrapInboundIn(data) {
        case .head(let h):
            guard server.accepting else { respond(context,503,["error":"service-stopping"]);return }
            guard head==nil, h.headers.reduce(0,{$0+$1.name.utf8.count+$1.value.utf8.count})<=16_384 else { respond(context,400,["error":"invalid-request"]); return }
            head=h
            let host="127.0.0.1:\(server.port)"
            guard h.headers["host"] == [host], h.headers["origin"].isEmpty || h.headers["origin"] == ["http://"+host] else { respond(context,403,["error":"invalid-origin"]); return }
            guard h.headers["authorization"].count==1, server.authenticated(h.headers.first(name:"authorization")) else { respond(context,401,["error":"unauthorized"]); return }
            guard h.headers["transfer-encoding"].isEmpty, h.headers["content-length"].count<=1 else { respond(context,400,["error":"invalid-request"]); return }
        case .body(var buf):
            guard body.count+buf.readableBytes<=4096 else { respond(context,413,["error":"body-too-large"]); return }
            if let bytes=buf.readBytes(length:buf.readableBytes) { body.append(contentsOf:bytes) }
        case .end:
            guard let h=head else { context.close(promise:nil); return }
            handling=true
            let content=body
            Task {
                do {
                    var object:JSONObject=[:]
                    if !content.isEmpty {
                        guard h.headers.first(name:"content-type")?.split(separator:";").first=="application/json" else { throw RuneError("json-required",httpStatus:415) }
                        guard let value=try? JSONSerialization.jsonObject(with:content) as? JSONObject else { throw RuneError("invalid-json",httpStatus:400) }
                        object=value
                    }
                    let result:JSONObject
                    switch (h.method,h.uri) {
                    case (.GET,"/api/status"): result=await server.coordinator.status()
                    case (.GET,"/api/events"):
                        let view=await server.coordinator.status()
                        context.eventLoop.execute {
                            self.timeout?.cancel()
                            let response=HTTPResponseHead(version:.http1_1,status:.ok,headers:["Content-Type":"text/event-stream","Cache-Control":"no-store","X-Content-Type-Options":"nosniff","Connection":"keep-alive"])
                            context.write(self.wrapOutboundOut(.head(response)),promise:nil)
                            self.server.subscribe(context.channel,view:view)
                        }; return
                    case (.POST,"/api/refresh"): result=await server.coordinator.refresh(manual:true)
                    case (.PATCH,"/api/config"): result=try await server.coordinator.configure(object)
                    case (.POST,"/api/bind"): result=try await server.coordinator.bind(object["consent"] as? String)
                    default: throw RuneError("not-found",httpStatus:404)
                    }
                    context.eventLoop.execute { self.respond(context,200,result) }
                } catch {
                    let err=error as? RuneError
                    context.eventLoop.execute { self.respond(context,err?.httpStatus ?? 500,["error":err?.code ?? "service-error"]) }
                }
            }
        }
    }
    func respond(_ context:ChannelHandlerContext,_ status:Int,_ value:JSONObject) {
        handling=true; timeout?.cancel()
        let data=server.encode(value)
        var headers=HTTPHeaders([("Content-Type","application/json"),("Cache-Control","no-store"),("Content-Length",String(data.count)),("Connection","close"),("X-Content-Type-Options","nosniff")])
        headers.add(name:"Referrer-Policy",value:"no-referrer")
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version:.http1_1,status:HTTPResponseStatus(statusCode:status),headers:headers))),promise:nil)
        var buffer=context.channel.allocator.buffer(capacity:data.count); buffer.writeBytes(data)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))),promise:nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in context.close(promise:nil) }
    }
}
