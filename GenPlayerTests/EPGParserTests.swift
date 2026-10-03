import XCTest
@testable import GenPlayerCore

final class EPGParserTests: XCTestCase {
    
    // MARK: - XMLTV Date Parser Tests
    
    func testXMLTVDateParserStandardFormat() {
        let dateString = "20260821200000 +0800"
        let date = XMLTVDateParser.parse(dateString)
        XCTAssertNotNil(date)
        
        let calendar = Calendar(identifier: .gregorian)
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 21
        components.hour = 20
        components.minute = 0
        components.second = 0
        components.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        
        let expected = calendar.date(from: components)
        XCTAssertEqual(date, expected)
    }
    
    func testXMLTVDateParserNegativeTimezone() {
        let dateString = "20260821123045 -0500"
        let date = XMLTVDateParser.parse(dateString)
        XCTAssertNotNil(date)
        
        let calendar = Calendar(identifier: .gregorian)
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 21
        components.hour = 12
        components.minute = 30
        components.second = 45
        components.timeZone = TimeZone(secondsFromGMT: -5 * 3600)
        
        let expected = calendar.date(from: components)
        XCTAssertEqual(date, expected)
    }
    
    func testXMLTVDateParserShortDate() {
        let dateString = "20260821"
        let date = XMLTVDateParser.parse(dateString)
        XCTAssertNotNil(date)
    }
    
    // MARK: - Channel Normalization Tests
    
    func testChannelNormalization() {
        let raw1 = "CCTV-1 4K [HEVC]"
        let norm1 = EPGTable.normalizeIdentifier(raw1)
        XCTAssertEqual(norm1, "cctv1")
        
        let raw2 = "CCTV-1 HD"
        let norm2 = EPGTable.normalizeIdentifier(raw2)
        XCTAssertEqual(norm2, "cctv1")
        
        let raw3 = "CCTV1"
        let norm3 = EPGTable.normalizeIdentifier(raw3)
        XCTAssertEqual(norm3, "cctv1")
        
        let raw4 = "[4K] CCTV-13 新闻 (1080P)"
        let norm4 = EPGTable.normalizeIdentifier(raw4)
        XCTAssertEqual(norm4, "cctv13新闻")
        
        let raw5 = "HBO HD (East)"
        let norm5 = EPGTable.normalizeIdentifier(raw5)
        XCTAssertEqual(norm5, "hboeast")
    }
    
    // MARK: - XMLTV SAX Parser Tests
    
    func testXMLTVParser() throws {
        let sampleXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tv generator-info-name="test" generator-info-url="https://test.com">
            <channel id="CCTV1">
                <display-name>CCTV-1 综合</display-name>
                <display-name>CCTV1</display-name>
                <icon src="https://example.com/cctv1.png" />
            </channel>
            <channel id="CCTV2">
                <display-name>CCTV-2 财经</display-name>
                <icon src="https://example.com/cctv2.png" />
            </channel>
            <programme start="20260821190000 +0800" stop="20260821193000 +0800" channel="CCTV1">
                <title lang="zh">新闻联播</title>
                <desc lang="zh">全国主要新闻联播节目。</desc>
            </programme>
            <programme start="20260821193000 +0800" stop="20260821193500 +0800" channel="CCTV1">
                <title lang="zh">天气预报</title>
            </programme>
            <programme start="20260821200000 +0800" stop="20260821210000 +0800" channel="CCTV2">
                <title lang="zh">经济半小时</title>
            </programme>
        </tv>
        """
        
        let data = sampleXML.data(using: .utf8)!
        let parsed = XMLTVParser.parse(data: data, pruneOlderThan: nil, pruneNewerThan: nil)
        
        XCTAssertEqual(parsed.channels.count, 2)
        XCTAssertEqual(parsed.channels["CCTV1"]?.displayName, "CCTV-1 综合")
        XCTAssertEqual(parsed.channels["CCTV1"]?.iconURL, URL(string: "https://example.com/cctv1.png"))
        
        let table = EPGTable(
            serverId: UUID(),
            channelsById: parsed.channels,
            programmesByChannel: parsed.programmes
        )
        
        // Test channel lookup with tvg-id
        let ch1 = IPTVChannel(id: "1", name: "CCTV 1", tvgId: "CCTV1", url: URL(string: "http://test.com/1.m3u8")!)
        let progs1 = table.allProgrammes(for: ch1)
        XCTAssertEqual(progs1.count, 2)
        XCTAssertEqual(progs1.first?.title, "新闻联播")
        XCTAssertEqual(progs1.first?.desc, "全国主要新闻联播节目。")
        
        // Test channel lookup with channel name fuzzy match
        let ch2 = IPTVChannel(id: "2", name: "CCTV-2 财经 HD [1080P]", url: URL(string: "http://test.com/2.m3u8")!)
        let progs2 = table.allProgrammes(for: ch2)
        XCTAssertEqual(progs2.count, 1)
        XCTAssertEqual(progs2.first?.title, "经济半小时")
    }
    
    // MARK: - Gzip Decompressor Tests
    
    func testGzipDecompressorNonGzipData() throws {
        let plainData = "Hello World".data(using: .utf8)!
        XCTAssertFalse(GzipDecompressor.isGzipped(data: plainData))
        
        let result = try GzipDecompressor.decompress(data: plainData)
        XCTAssertEqual(result, plainData)
    }
}
