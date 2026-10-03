import Foundation
import Testing
@testable import GenPlayer

struct ICloudServerListSyncTests {
    @Test("Newer remote payload preserves local secrets and reports removed servers")
    func newerRemotePayloadMergesWithLocalSecrets() {
        let localServer = ServerConfig(
            id: UUID(),
            name: "Living Room Jellyfin",
            address: "jellyfin.local",
            port: 8096,
            useSSL: false,
            type: .jellyfin,
            username: "gary",
            passwordSecret: "secret-password",
            workgroup: nil,
            accessToken: "local-token",
            userId: "user-1"
        )
        let removedLocalServer = ServerConfig(
            id: UUID(),
            name: "Old SMB",
            address: "nas.local",
            port: 445,
            useSSL: false,
            type: .smb,
            username: "guest",
            passwordSecret: "guest-pass",
            workgroup: "WORKGROUP",
            accessToken: nil,
            userId: nil
        )
        let remoteUpdatedServer = ServerConfig(
            id: localServer.id,
            name: "Living Room Jellyfin Updated",
            address: "media.example.com/jellyfin",
            port: 8920,
            useSSL: true,
            type: .jellyfin,
            username: "gary",
            passwordSecret: nil,
            workgroup: nil,
            accessToken: nil,
            userId: "user-1"
        )
        let remoteAddedServer = ServerConfig(
            id: UUID(),
            name: "Bedroom WebDAV",
            address: "dav.example.com/media",
            port: 443,
            useSSL: true,
            type: .webdav,
            username: "gary",
            passwordSecret: nil,
            workgroup: nil,
            accessToken: nil,
            userId: nil
        )

        let resolution = ICloudServerListSyncResolver.resolve(
            localServers: [localServer, removedLocalServer],
            localUpdatedAt: 100,
            remotePayload: ICloudServerListPayload(
                updatedAt: 200,
                servers: [remoteUpdatedServer, remoteAddedServer]
            )
        )

        guard let resolution else {
            Issue.record("Expected a newer remote payload to produce a sync resolution")
            return
        }

        #expect(resolution.updatedAt == 200)
        #expect(resolution.removedServerIDs == [removedLocalServer.id])
        #expect(resolution.servers.count == 2)
        #expect(resolution.servers[0].id == localServer.id)
        #expect(resolution.servers[0].name == remoteUpdatedServer.name)
        #expect(resolution.servers[0].address == remoteUpdatedServer.address)
        #expect(resolution.servers[0].passwordSecret == localServer.passwordSecret)
        #expect(resolution.servers[0].accessToken == localServer.accessToken)
        #expect(resolution.servers[1] == remoteAddedServer)
    }

    @Test("Older remote payload does not overwrite local servers")
    func olderRemotePayloadIsIgnored() {
        let localServer = ServerConfig(
            id: UUID(),
            name: "Office Plex",
            address: "plex.local",
            port: 32400,
            useSSL: false,
            type: .plex,
            username: "gary",
            passwordSecret: nil,
            workgroup: nil,
            accessToken: nil,
            userId: nil
        )
        let remotePayload = ICloudServerListPayload(
            updatedAt: 150,
            servers: [
                ServerConfig(
                    id: localServer.id,
                    name: "Office Plex Updated",
                    address: "plex.example.com",
                    port: 32400,
                    useSSL: true,
                    type: .plex,
                    username: "gary",
                    passwordSecret: nil,
                    workgroup: nil,
                    accessToken: nil,
                    userId: nil
                )
            ]
        )

        let resolution = ICloudServerListSyncResolver.resolve(
            localServers: [localServer],
            localUpdatedAt: 300,
            remotePayload: remotePayload
        )

        #expect(resolution == nil)
    }

    @Test("Newer remote timestamp still advances sync state for unchanged lists")
    func newerTimestampForSameListStillResolves() {
        let localServer = ServerConfig(
            id: UUID(),
            name: "Family SMB",
            address: "smb.local/share",
            port: 445,
            useSSL: false,
            type: .smb,
            username: "family",
            passwordSecret: "keep-local-secret",
            workgroup: "HOME",
            accessToken: nil,
            userId: nil
        )
        let remoteServer = ServerConfig(
            id: localServer.id,
            name: localServer.name,
            address: localServer.address,
            port: localServer.port,
            useSSL: localServer.useSSL,
            type: localServer.type,
            username: localServer.username,
            passwordSecret: nil,
            workgroup: localServer.workgroup,
            accessToken: nil,
            userId: localServer.userId
        )

        let resolution = ICloudServerListSyncResolver.resolve(
            localServers: [localServer],
            localUpdatedAt: 10,
            remotePayload: ICloudServerListPayload(updatedAt: 20, servers: [remoteServer])
        )

        guard let resolution else {
            Issue.record("Expected a newer timestamp to advance local sync state")
            return
        }

        #expect(resolution.updatedAt == 20)
        #expect(resolution.removedServerIDs.isEmpty)
        #expect(resolution.servers.count == 1)
        #expect(resolution.servers[0].passwordSecret == localServer.passwordSecret)
        #expect(resolution.servers[0].address == localServer.address)
    }
}
