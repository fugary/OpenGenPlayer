import Foundation

public enum ServerAuthStyle: Equatable {
    /// 标准用户名 + 密码（WebDAV, AList, Jellyfin, Emby, FTP, SFTP, NFS）
    case credentials
    /// 用户名 + 密码 + 工作组（SMB）
    case smb
    /// 地址/端口 + Plex PIN 网页/扫码授权 + Access Token
    case plex
    /// 115 云盘专属授权（二维码扫码登录 / Web 登录 / Cookie）
    case pan115
    /// OneDrive 微软云盘专属授权（OAuth / 设备码）
    case onedrive
    /// Google Drive 谷歌云盘专属授权（OAuth / 设备码）
    case googledrive
    /// 播放列表 URL/文件路径 + 自定义 EPG（IPTV）
    case iptv
    /// VOD API Base URL (Web VOD)
    case vod
}

public struct ServerFormSpec: Equatable {
    public let type: ServerConfig.ServerType
    public let authStyle: ServerAuthStyle
    public let requiresAddressInput: Bool
    public let fixedAddress: String?
    public let addressPlaceholder: String
    public let requiresPortInput: Bool
    public let fixedPort: Int?
    public let allowsSSL: Bool
    public let defaultSSL: Bool
    public let defaultServerName: String
    public let showsWorkgroup: Bool
    public let showsCustomEPG: Bool

    public func defaultPort(useSSL: Bool) -> Int {
        ServerConfig.defaultPort(for: type, useSSL: useSSL)
    }

    public static func spec(for type: ServerConfig.ServerType) -> ServerFormSpec {
        switch type {
        case .smb:
            return ServerFormSpec(
                type: .smb,
                authStyle: .smb,
                requiresAddressInput: true,
                fixedAddress: nil,
                addressPlaceholder: "192.168.1.1",
                requiresPortInput: true,
                fixedPort: nil,
                allowsSSL: false,
                defaultSSL: false,
                defaultServerName: "SMB",
                showsWorkgroup: true,
                showsCustomEPG: false
            )
        case .webdav:
            return ServerFormSpec(
                type: .webdav,
                authStyle: .credentials,
                requiresAddressInput: true,
                fixedAddress: nil,
                addressPlaceholder: "nas.local/webdav",
                requiresPortInput: true,
                fixedPort: nil,
                allowsSSL: true,
                defaultSSL: false,
                defaultServerName: "WebDAV",
                showsWorkgroup: false,
                showsCustomEPG: false
            )
        case .ftp:
            return ServerFormSpec(
                type: .ftp,
                authStyle: .credentials,
                requiresAddressInput: true,
                fixedAddress: nil,
                addressPlaceholder: "ftp.example.com/media",
                requiresPortInput: true,
                fixedPort: nil,
                allowsSSL: false,
                defaultSSL: false,
                defaultServerName: "FTP",
                showsWorkgroup: false,
                showsCustomEPG: false
            )
        case .sftp:
            return ServerFormSpec(
                type: .sftp,
                authStyle: .credentials,
                requiresAddressInput: true,
                fixedAddress: nil,
                addressPlaceholder: "sftp.example.com/media",
                requiresPortInput: true,
                fixedPort: nil,
                allowsSSL: false,
                defaultSSL: false,
                defaultServerName: "SFTP",
                showsWorkgroup: false,
                showsCustomEPG: false
            )
        case .nfs:
            return ServerFormSpec(
                type: .nfs,
                authStyle: .credentials,
                requiresAddressInput: true,
                fixedAddress: nil,
                addressPlaceholder: "nas.local/volume1/media",
                requiresPortInput: true,
                fixedPort: nil,
                allowsSSL: false,
                defaultSSL: false,
                defaultServerName: "NFS",
                showsWorkgroup: false,
                showsCustomEPG: false
            )
        case .jellyfin:
            return ServerFormSpec(
                type: .jellyfin,
                authStyle: .credentials,
                requiresAddressInput: true,
                fixedAddress: nil,
                addressPlaceholder: "192.168.1.1",
                requiresPortInput: true,
                fixedPort: nil,
                allowsSSL: true,
                defaultSSL: false,
                defaultServerName: "Jellyfin",
                showsWorkgroup: false,
                showsCustomEPG: false
            )
        case .emby:
            return ServerFormSpec(
                type: .emby,
                authStyle: .credentials,
                requiresAddressInput: true,
                fixedAddress: nil,
                addressPlaceholder: "192.168.1.1",
                requiresPortInput: true,
                fixedPort: nil,
                allowsSSL: true,
                defaultSSL: false,
                defaultServerName: "Emby",
                showsWorkgroup: false,
                showsCustomEPG: false
            )
        case .plex:
            return ServerFormSpec(
                type: .plex,
                authStyle: .plex,
                requiresAddressInput: true,
                fixedAddress: nil,
                addressPlaceholder: "192.168.1.1",
                requiresPortInput: true,
                fixedPort: nil,
                allowsSSL: true,
                defaultSSL: false,
                defaultServerName: "Plex",
                showsWorkgroup: false,
                showsCustomEPG: false
            )
        case .alist:
            return ServerFormSpec(
                type: .alist,
                authStyle: .credentials,
                requiresAddressInput: true,
                fixedAddress: nil,
                addressPlaceholder: "192.168.1.1",
                requiresPortInput: true,
                fixedPort: nil,
                allowsSSL: true,
                defaultSSL: false,
                defaultServerName: "AList",
                showsWorkgroup: false,
                showsCustomEPG: false
            )
        case .pan115:
            return ServerFormSpec(
                type: .pan115,
                authStyle: .pan115,
                requiresAddressInput: false,
                fixedAddress: "115.com",
                addressPlaceholder: "115.com",
                requiresPortInput: false,
                fixedPort: 443,
                allowsSSL: false,
                defaultSSL: true,
                defaultServerName: "115",
                showsWorkgroup: false,
                showsCustomEPG: false
            )
        case .onedrive:
            return ServerFormSpec(
                type: .onedrive,
                authStyle: .onedrive,
                requiresAddressInput: false,
                fixedAddress: "graph.microsoft.com",
                addressPlaceholder: "graph.microsoft.com",
                requiresPortInput: false,
                fixedPort: 443,
                allowsSSL: false,
                defaultSSL: true,
                defaultServerName: "OneDrive",
                showsWorkgroup: false,
                showsCustomEPG: false
            )
        case .googledrive:
            return ServerFormSpec(
                type: .googledrive,
                authStyle: .googledrive,
                requiresAddressInput: false,
                fixedAddress: "www.googleapis.com",
                addressPlaceholder: "www.googleapis.com",
                requiresPortInput: false,
                fixedPort: 443,
                allowsSSL: false,
                defaultSSL: true,
                defaultServerName: "Google Drive",
                showsWorkgroup: false,
                showsCustomEPG: false
            )
        case .iptv:
            return ServerFormSpec(
                type: .iptv,
                authStyle: .iptv,
                requiresAddressInput: true,
                fixedAddress: nil,
                addressPlaceholder: "https://example.com/playlist.m3u",
                requiresPortInput: false,
                fixedPort: nil,
                allowsSSL: true,
                defaultSSL: false,
                defaultServerName: "IPTV",
                showsWorkgroup: false,
                showsCustomEPG: true
            )
        case .vod:
            return ServerFormSpec(
                type: .vod,
                authStyle: .vod,
                requiresAddressInput: true,
                fixedAddress: nil,
                addressPlaceholder: "https://example.com/api.php/provide/vod",
                requiresPortInput: false,
                fixedPort: nil,
                allowsSSL: true,
                defaultSSL: false,
                defaultServerName: "Web VOD",
                showsWorkgroup: false,
                showsCustomEPG: false
            )
        }
    }
}

public struct ServerTypeDraft: Equatable {
    public var name: String
    public var address: String
    public var portString: String
    public var useSSL: Bool
    public var username: String
    public var password: String
    public var workgroup: String
    public var customEPGURL: String
    public var accessToken: String
    public var userId: String?

    public init(
        name: String = "",
        address: String = "",
        portString: String = "",
        useSSL: Bool = false,
        username: String = "",
        password: String = "",
        workgroup: String = "",
        customEPGURL: String = "",
        accessToken: String = "",
        userId: String? = nil
    ) {
        self.name = name
        self.address = address
        self.portString = portString
        self.useSSL = useSSL
        self.username = username
        self.password = password
        self.workgroup = workgroup
        self.customEPGURL = customEPGURL
        self.accessToken = accessToken
        self.userId = userId
    }

    /// 根据类型和已有服务器初始化草稿。如果是编辑已有服务器且类型匹配，则水合已有值；否则初始化干净的类型默认值
    public static func initial(for type: ServerConfig.ServerType, existing: ServerConfig? = nil) -> ServerTypeDraft {
        let spec = ServerFormSpec.spec(for: type)
        if let existing = existing, existing.type == type {
            let effAddr = spec.fixedAddress ?? existing.address
            let effPort = spec.fixedPort.map(String.init) ?? (existing.port.map(String.init) ?? "")
            let effSSL = spec.fixedAddress != nil ? spec.defaultSSL : existing.useSSL
            return ServerTypeDraft(
                name: existing.name,
                address: effAddr,
                portString: effPort,
                useSSL: effSSL,
                username: existing.username ?? "",
                password: existing.passwordSecret ?? "",
                workgroup: existing.workgroup ?? "",
                customEPGURL: existing.customEPGURL ?? "",
                accessToken: existing.accessToken ?? "",
                userId: existing.userId
            )
        }

        return ServerTypeDraft(
            name: spec.defaultServerName,
            address: spec.fixedAddress ?? "",
            portString: spec.fixedPort.map(String.init) ?? "",
            useSSL: spec.defaultSSL,
            username: "",
            password: "",
            workgroup: "",
            customEPGURL: "",
            accessToken: "",
            userId: nil
        )
    }

    /// 校验当前草稿是否具备可保存的最小完整性
    public func isValidForSave(spec: ServerFormSpec) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return false }

        if spec.authStyle == .pan115 {
            return !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } else if spec.authStyle == .onedrive || spec.authStyle == .googledrive {
            return !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                   !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } else {
            return !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// 生成可用于测试或保存的 ServerConfig
    public func buildServerConfig(type: ServerConfig.ServerType, id: UUID = UUID()) -> ServerConfig {
        let spec = ServerFormSpec.spec(for: type)
        let effectiveAddress = spec.fixedAddress ?? address.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveSSL = spec.fixedAddress != nil ? spec.defaultSSL : useSSL
        let parsedPort = spec.fixedPort ?? Int(portString.trimmingCharacters(in: .whitespacesAndNewlines))
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveName = trimmedName.isEmpty ? type.displayName : trimmedName
        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPass = password.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedWorkgroup = workgroup.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEPG = customEPGURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)

        return ServerConfig(
            id: id,
            name: effectiveName,
            address: effectiveAddress,
            port: parsedPort,
            useSSL: effectiveSSL,
            type: type,
            username: trimmedUser.isEmpty ? nil : trimmedUser,
            passwordSecret: (type == .plex && trimmedPass.isEmpty) ? nil : (trimmedPass.isEmpty ? nil : trimmedPass),
            workgroup: (spec.showsWorkgroup && !trimmedWorkgroup.isEmpty) ? trimmedWorkgroup : nil,
            accessToken: trimmedToken.isEmpty ? nil : trimmedToken,
            userId: userId,
            customEPGURL: (spec.showsCustomEPG && !trimmedEPG.isEmpty) ? trimmedEPG : nil
        )
    }
}
