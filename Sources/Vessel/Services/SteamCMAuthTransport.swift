import Foundation

/// Transporte mínimo para los métodos públicos de `IAuthenticationService` que un cliente Steam
/// de escritorio debe enviar por CM. No inicia una sesión de usuario ni implementa Steamworks: abre
/// un CM anónimo, envía `ServiceMethodCallFromClientNonAuthed` y correlaciona cada respuesta por job.
actor SteamCMAuthTransport {
    private struct CMDirectoryResponse: Decodable {
        struct Response: Decodable {
            struct Server: Decodable {
                let endpoint: String
                let type: String
                let realm: String
                let wtd_load: Double?
            }
            let serverlist: [Server]
        }
        let response: Response
    }

    private struct Packet {
        let emsg: UInt32
        let header: ProtoReader
        let body: Data
    }

    private static let protobufMask: UInt32 = 0x8000_0000
    private static let emsgMulti: UInt32 = 1
    private static let emsgServiceMethodCallFromClientNonAuthed: UInt32 = 9804
    private static let emsgClientHello: UInt32 = 9805
    private static let protocolVersion: UInt64 = 65_580

    private var webSocket: URLSessionWebSocketTask?
    private var receiveLoopTask: Task<Void, Never>?
    private var pending: [UInt64: CheckedContinuation<Data, Error>] = [:]
    private var requestBusy = false
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var cmServers: [String] = []
    private var nextServerIndex = 0

    func request(method: String, body: Data) async throws -> Data {
        await acquireRequestTurn()
        defer { releaseRequestTurn() }

        var lastError: Error?
        for _ in 0..<3 {
            do {
                try await ensureConnected()
                return try await sendServiceRequest(method: method, body: body)
            } catch {
                lastError = error
                resetConnection(error: error)
            }
        }
        throw lastError ?? transportError("Steam no respondió al canal de autenticación CM.")
    }

    func close() {
        resetConnection(error: transportError("Canal de autenticación Steam cerrado."))
    }

    private func acquireRequestTurn() async {
        if !requestBusy {
            requestBusy = true
            return
        }
        await withCheckedContinuation { requestWaiters.append($0) }
    }

    private func releaseRequestTurn() {
        if requestWaiters.isEmpty {
            requestBusy = false
        } else {
            requestWaiters.removeFirst().resume()
        }
    }

    private func ensureConnected() async throws {
        if let webSocket, webSocket.state == .running { return }
        if cmServers.isEmpty { cmServers = try await fetchCMServers() }
        guard !cmServers.isEmpty else {
            throw transportError("Steam no devolvió servidores CM compatibles.")
        }

        let endpoint = cmServers[nextServerIndex % cmServers.count]
        nextServerIndex += 1
        guard let url = URL(string: "wss://\(endpoint)/cmsocket/") else {
            throw transportError("Steam devolvió un servidor CM inválido.")
        }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("Valve/Steam HTTP Client 1.0", forHTTPHeaderField: "User-Agent")
        let socket = URLSession.shared.webSocketTask(with: request)
        webSocket = socket
        socket.resume()

        var hello = Data()
        hello.append(ProtoWriter.varint(field: 1, Self.protocolVersion))
        let helloPacket = Self.packet(
            emsg: Self.emsgClientHello,
            header: Self.baseHeader(clientSessionID: 0),
            body: hello
        )
        do {
            try await socket.send(.data(helloPacket))
        } catch {
            socket.cancel(with: .goingAway, reason: nil)
            webSocket = nil
            throw error
        }

        let taskID = socket.taskIdentifier
        receiveLoopTask = Task { [weak self] in
            await self?.receiveMessages(from: socket, taskID: taskID)
        }
    }

    private func fetchCMServers() async throws -> [String] {
        guard let url = URL(string: "https://api.steampowered.com/ISteamDirectory/GetCMListForConnect/v0001/?cellid=0&format=json") else {
            throw transportError("No se pudo construir la consulta de servidores Steam.")
        }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("Valve/Steam HTTP Client 1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw transportError("Steam no devolvió su directorio CM.")
        }
        let decoded = try JSONDecoder().decode(CMDirectoryResponse.self, from: data)
        return decoded.response.serverlist
            .filter { $0.type == "websockets" && $0.realm == "steamglobal" }
            .sorted { ($0.wtd_load ?? .greatestFiniteMagnitude) < ($1.wtd_load ?? .greatestFiniteMagnitude) }
            .map(\.endpoint)
    }

    private func sendServiceRequest(method: String, body: Data) async throws -> Data {
        guard let socket = webSocket, socket.state == .running else {
            throw transportError("El canal CM de Steam no está conectado.")
        }
        let jobID = UInt64.random(in: 1...UInt64.max) & 0x7fff_ffff_ffff_ffff

        var header = Self.baseHeader(clientSessionID: 0)
        header.append(ProtoWriter.fixed64(field: 10, jobID))
        header.append(ProtoWriter.string(field: 12, "Authentication.\(method)#1"))
        header.append(ProtoWriter.varint(field: 32, 1))
        let encoded = Self.packet(
            emsg: Self.emsgServiceMethodCallFromClientNonAuthed,
            header: header,
            body: body
        )

        return try await withCheckedThrowingContinuation { continuation in
            pending[jobID] = continuation
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await socket.send(.data(encoded))
                } catch {
                    await self.fail(jobID: jobID, error: error)
                    return
                }
                try? await Task.sleep(for: .seconds(12))
                await self.timeout(jobID: jobID, method: method)
            }
        }
    }

    private func receiveMessages(from socket: URLSessionWebSocketTask, taskID: Int) async {
        do {
            while socket.state == .running {
                let message = try await socket.receive()
                let data: Data
                switch message {
                case .data(let value): data = value
                case .string(let value): data = Data(value.utf8)
                @unknown default: continue
                }
                try handleIncoming(data)
            }
        } catch {
            guard webSocket?.taskIdentifier == taskID else { return }
            resetConnection(error: error)
        }
    }

    private func handleIncoming(_ data: Data) throws {
        for packet in try Self.unpackPackets(data) {
            guard let jobID = packet.header.varint(11), let continuation = pending.removeValue(forKey: jobID) else {
                continue
            }
            let result = packet.header.varint(13) ?? 1
            if result == 1 {
                continuation.resume(returning: packet.body)
            } else {
                let message = packet.header.string(14) ?? "Steam rechazó la solicitud de autenticación (EResult \(result))."
                continuation.resume(throwing: transportError(message))
            }
        }
    }

    private func fail(jobID: UInt64, error: Error) {
        pending.removeValue(forKey: jobID)?.resume(throwing: error)
    }

    private func timeout(jobID: UInt64, method: String) {
        pending.removeValue(forKey: jobID)?.resume(
            throwing: transportError("Steam no respondió a \(method) dentro del tiempo esperado.")
        )
    }

    private func resetConnection(error: Error) {
        receiveLoopTask?.cancel()
        receiveLoopTask = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        let continuations = pending.values
        pending.removeAll()
        continuations.forEach { $0.resume(throwing: error) }
    }

    private static func baseHeader(clientSessionID: UInt64) -> Data {
        var header = Data()
        header.append(ProtoWriter.fixed64(field: 1, 0))
        header.append(ProtoWriter.varint(field: 2, clientSessionID))
        return header
    }

    private static func packet(emsg: UInt32, header: Data, body: Data) -> Data {
        var result = Data()
        result.appendUInt32LE(emsg | protobufMask)
        result.appendUInt32LE(UInt32(header.count))
        result.append(header)
        result.append(body)
        return result
    }

    private static func unpackPackets(_ data: Data) throws -> [Packet] {
        guard data.count >= 8 else { throw transportError("Steam envió un paquete CM incompleto.") }
        let rawEMsg = data.readUInt32LE(at: 0)
        let headerLength = Int(data.readUInt32LE(at: 4))
        guard rawEMsg & protobufMask != 0, headerLength >= 0, 8 + headerLength <= data.count else {
            throw transportError("Steam envió un paquete CM no compatible.")
        }
        let emsg = rawEMsg & ~protobufMask
        let header = ProtoReader.parse(data.subdata(in: 8..<(8 + headerLength)))
        let body = data.subdata(in: (8 + headerLength)..<data.count)
        if emsg != emsgMulti { return [Packet(emsg: emsg, header: header, body: body)] }

        let multi = ProtoReader.parse(body)
        guard var payload = multi.bytes(2) else { return [] }
        if (multi.varint(1) ?? 0) > 0 {
            payload = try (payload as NSData).decompressed(using: .zlib) as Data
        }
        var packets: [Packet] = []
        var offset = 0
        while offset + 4 <= payload.count {
            let length = Int(payload.readUInt32LE(at: offset))
            offset += 4
            guard length >= 0, offset + length <= payload.count else {
                throw transportError("Steam envió un paquete múltiple CM incompleto.")
            }
            packets.append(contentsOf: try unpackPackets(payload.subdata(in: offset..<(offset + length))))
            offset += length
        }
        return packets
    }

    private static func transportError(_ message: String) -> NSError {
        NSError(domain: "Vessel.SteamCM", code: 51, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func transportError(_ message: String) -> NSError { Self.transportError(message) }
}

private extension Data {
    mutating func appendUInt32LE(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    func readUInt32LE(at offset: Int) -> UInt32 {
        subdata(in: offset..<(offset + 4)).withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))
        }
    }
}
