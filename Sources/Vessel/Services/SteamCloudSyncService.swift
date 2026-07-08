import Foundation
import CryptoKit

/// ⚠️ **LEGADO — NO USADO ACTUALMENTE.** La Web API `ICloudService` resultó ser *publisher-only*
/// (devuelve 401 con el `access_token` de cliente), así que la nube real se resolvió por otra vía:
/// el **modo Steam real** (`WineManager.launchViaRealSteam`), que lanza el juego con el cliente de
/// Steam conectado y deja que el propio Steam sincronice la nube — como CrossOver. Este servicio se
/// conserva por si Valve habilitara el acceso de cliente a `ICloudService`; hoy no lo invoca nadie
/// (verificado). NO borrar sin confirmar que el modo Steam real cubre todos los casos.
///
/// Sincronización con **Steam Cloud REAL** vía la Web API `ICloudService` (HTTP puro + el
/// `access_token` de cliente que ya obtiene `SteamAuthService`, sin el cliente Steam corriendo).
///
/// **Coexiste** con `SaveBackupManager` (backup local por snapshots): el backup local es la red de
/// seguridad del usuario (se mantiene intacto); este servicio AÑADE la sincronización con la nube de
/// Steam para poder seguir la partida en otro dispositivo, como hace CrossOver. El backup local corre
/// SIEMPRE; el de Steam Cloud solo si hay sesión de Steam (token) y el juego usa Steam Cloud.
///
/// Modelo Web API (validado en la spec, ver memoria `steam-cloud-sync`): todo va en CRUDO (sin
/// comprimir ni cifrar). Enumerar → descargar por la `url` que devuelve → subir por lote
/// (BeginAppUploadBatch → por archivo BeginHTTPUpload+PUT+CommitHTTPUpload → CompleteAppUploadBatch).
actor SteamCloudSyncService {
    static let shared = SteamCloudSyncService()

    private let base = "https://api.steampowered.com/ICloudService"
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 300
        return URLSession(configuration: c)
    }()

    /// Un archivo tal como lo reporta la nube de Steam para un appid.
    struct CloudFile: Sendable {
        let filename: String   // ruta relativa aplanada con `/` (p. ej. "remote/save.dat")
        let timestamp: UInt64  // epoch de última modificación en la nube
        let fileSize: UInt32   // bytes del archivo crudo
        let url: String        // URL de descarga directa (con extended_details=1)
        let sha: String        // SHA1 hex de 40 del archivo crudo
    }

    // MARK: - Token de cliente (se refresca solo; vacío si no hay sesión Steam)
    private func token() async -> String? {
        let t = await SteamAuthService.currentAccessToken()
        return t.isEmpty ? nil : t
    }

    /// ¿Hay sesión de Steam con la que sincronizar la nube?
    func hasSession() async -> Bool { await token() != nil }

    // MARK: - Enumerar los archivos en la nube de un appid (paginado)
    func enumerate(appId: String) async -> [CloudFile] {
        guard let tok = await token() else { return [] }
        var out: [CloudFile] = []
        var start = 0
        while true {
            let urlStr = "\(base)/EnumerateUserFiles/v1/?access_token=\(tok)&appid=\(appId)&extended_details=1&count=500&start_index=\(start)"
            guard let u = URL(string: urlStr),
                  let (data, resp) = try? await session.data(from: u),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let response = root["response"] as? [String: Any] else { break }
            let files = (response["files"] as? [[String: Any]]) ?? []
            for f in files {
                guard let name = f["filename"] as? String else { continue }
                out.append(CloudFile(
                    filename: name,
                    timestamp: Self.u64(f["timestamp"]),
                    fileSize: UInt32(truncatingIfNeeded: Self.u64(f["file_size"])),
                    url: (f["url"] as? String) ?? "",
                    sha: ((f["file_sha"] as? String) ?? "").lowercased()))
            }
            let total = Int(Self.u64(response["total_files"]))
            start += files.count
            if files.isEmpty || out.count >= total { break }
        }
        return out
    }

    // MARK: - Descargar el contenido crudo de un archivo
    func download(_ file: CloudFile) async -> Data? {
        guard !file.url.isEmpty, let u = URL(string: file.url),
              let (data, resp) = try? await session.data(from: u),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    // MARK: - Subir/borrar archivos (lote obligatorio del Web API)
    /// Devuelve true si TODO el lote se subió y confirmó. Sube en crudo.
    @discardableResult
    func upload(appId: String, files: [(filename: String, data: Data)], deletes: [String] = []) async -> Bool {
        guard let tok = await token(), !(files.isEmpty && deletes.isEmpty) else { return false }

        // 1) Abrir el lote declarando de antemano qué se sube y qué se borra.
        var beginParams: [String: String] = ["appid": appId, "machine_name": "Vessel"]
        for (i, f) in files.enumerated() { beginParams["files_to_upload[\(i)]"] = f.filename }
        for (i, name) in deletes.enumerated() { beginParams["files_to_delete[\(i)]"] = name }
        guard let begin = await post("BeginAppUploadBatch", token: tok, params: beginParams),
              let batchId = Self.str(begin["batch_id"]) else { return false }

        var allOK = true

        // 2) Por archivo: BeginHTTPUpload → PUT a la URL devuelta → CommitHTTPUpload.
        for f in files {
            let sha = Self.sha1hex(f.data)
            let bhu = await post("BeginHTTPUpload", token: tok, params: [
                "appid": appId, "file_size": String(f.data.count),
                "filename": f.filename, "file_sha": sha, "upload_batch_id": batchId
            ])
            guard let bhu, let host = bhu["url_host"] as? String, let path = bhu["url_path"] as? String, !host.isEmpty else {
                allOK = false; continue
            }
            let https = (bhu["use_https"] as? Bool) ?? true
            let headers = (bhu["request_headers"] as? [[String: Any]]) ?? []
            let putURL = "\(https ? "https" : "http")://\(host)\(path)"
            let putOK = await putFile(putURL, headers: headers, body: f.data)
            _ = await post("CommitHTTPUpload", token: tok, params: [
                "appid": appId, "transfer_succeeded": putOK ? "1" : "0",
                "filename": f.filename, "file_sha": sha
            ])
            if !putOK { allOK = false }
        }

        // 3) Cerrar el lote (batch_eresult: 1 = k_EResultOK).
        _ = await post("CompleteAppUploadBatch", token: tok, params: [
            "appid": appId, "batch_id": batchId, "batch_eresult": allOK ? "1" : "2"
        ])
        return allOK
    }

    // MARK: - HTTP helpers
    /// POST form-urlencoded a un método de ICloudService; el token va en la query. Devuelve el objeto
    /// `response` del JSON (o el JSON raíz si no viene envuelto).
    private func post(_ method: String, token: String, params: [String: String]) async -> [String: Any]? {
        guard let u = URL(string: "\(base)/\(method)/v1/?access_token=\(token)") else { return nil }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = params
            .map { "\(Self.enc($0.key))=\(Self.enc($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (root?["response"] as? [String: Any]) ?? root
    }

    /// PUT de los bytes crudos a la URL de subida, con los headers que exige Steam.
    private func putFile(_ urlStr: String, headers: [[String: Any]], body: Data) async -> Bool {
        guard let u = URL(string: urlStr) else { return false }
        var req = URLRequest(url: u)
        req.httpMethod = "PUT"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        for h in headers {
            if let name = h["name"] as? String, let value = h["value"] as? String {
                req.setValue(value, forHTTPHeaderField: name)
            }
        }
        guard let (_, resp) = try? await session.upload(for: req, from: body),
              let code = (resp as? HTTPURLResponse)?.statusCode else { return false }
        return (200...299).contains(code)
    }

    // MARK: - Utilidades
    private static func sha1hex(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// La Web API de Steam devuelve los enteros grandes (timestamp, ugcid, file_size) como String o
    /// como Number según el caso: normalizamos a UInt64.
    private static func u64(_ v: Any?) -> UInt64 {
        if let n = v as? NSNumber { return n.uint64Value }
        if let s = v as? String { return UInt64(s) ?? 0 }
        return 0
    }
    private static func str(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }
    /// Percent-encoding estricto para form-urlencoded (encodea `/`, espacios, `&`, `=`, etc.).
    private static let formAllowed: CharacterSet = {
        var cs = CharacterSet.alphanumerics
        cs.insert(charactersIn: "-._~")
        return cs
    }()
    private static func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? s
    }
}
