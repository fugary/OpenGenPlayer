import Foundation

@main struct VODSourcesChecks {
    static func main() throws {
        var count = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message); count += 1
        }
        let legacy = ServerConfig(name: "Legacy", address: "https://example.com/api.php/provide/vod", type: .vod)
        let decoded = try JSONDecoder().decode(ServerConfig.self, from: JSONEncoder().encode(legacy))
        check(decoded.vodSources == nil, "Old server decodes without a collection")
        check(decoded.macVODEndpoints.first?.id == legacy.id, "Legacy endpoint preserves server identity")
        check(decoded.macVODResolveRecord("123")?.itemID == "123", "Old history resolves without migration")
        let second = VODSourceConfig(name: "Second", address: "https://second.example/api.php/provide/vod")
        var owner = legacy
        owner.vodSources = legacy.macVODSources + [second]
        let restored = try JSONDecoder().decode(ServerConfig.self, from: JSONEncoder().encode(owner))
        check(restored.vodSources == owner.vodSources, "Internal sources persist with stable identity and order")
        check(restored.macVODEndpoints.map(\.id) == [legacy.id, second.id], "Only this owner's sources are projected")
        let endpoints = restored.macVODEndpoints
        let oldID = endpoints[0].macVODRecordID(ownerID: owner.id, itemID: "123")
        let newID = endpoints[1].macVODRecordID(ownerID: owner.id, itemID: "123")
        check(oldID == "123" && oldID != newID, "Same raw item IDs cannot collide; legacy identity remains stable")
        check(owner.macVODResolveRecord(newID)?.source.id == second.id, "New history returns to its original source")
        owner.vodSources?.reverse()
        check(owner.macVODEndpoints.first?.id == second.id, "Order selects default source")
        check(owner.macVODResolveRecord(oldID)?.source.id == legacy.id, "Changing default never redirects legacy history")
        owner.vodSources?[0].isEnabled = false
        check(owner.macVODEndpoints.map(\.id) == [legacy.id], "Disabled sources cannot participate in searches")
        check(owner.macVODResolveRecord(newID) == nil, "Disabled sources cannot silently fall back")
        owner.vodSources?.removeFirst()
        check(owner.macVODResolveRecord(newID) == nil, "Removed source cannot resolve to another source")
        let otherOwner = ServerConfig(name: "Independent", address: "https://other.example", type: .vod)
        check(otherOwner.macVODResolveRecord(newID) == nil, "Record cannot cross server boundaries")
        let summaryIDs = restored.macVODSummaryEndpoints.map(\.id)
        var edited = restored
        edited.vodSources?[1].address = "https://replacement.example/api.php/provide/vod"
        check(edited.macVODSummaryEndpoints[1].id != summaryIDs[1], "Address edits isolate old counts and late responses")
        check(edited.macVODSummaryEndpoints[0].id == summaryIDs[0], "Unchanged source keeps its summary cache")
        let editedSummaryID = edited.macVODSummaryEndpoints[1].id
        edited.vodSources?[1].name = "Renamed"
        check(edited.macVODSummaryEndpoints[1].id == editedSummaryID, "Summary identity is deterministic")
        let decodedEdited = try JSONDecoder().decode(ServerConfig.self, from: JSONEncoder().encode(edited))
        check(decodedEdited.macVODSummaryEndpoints.map(\.id) == edited.macVODSummaryEndpoints.map(\.id), "Summary identity survives restart")
        check(edited.macVODEndpoints.map(\.id) == restored.macVODEndpoints.map(\.id), "Summary cache changes never alter playback identity")
        print("PASS: \(count) VOD source persistence and identity assertions; no GUI or network")
    }
}
