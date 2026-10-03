import XCTest
@testable import GenPlayerCore

final class VODParserTests: XCTestCase {

    // MARK: - Play Sources & Episodes Parsing Tests

    func testSingleSourcePlayList() {
        let playFrom = "test_source"
        let playUrl = "第01集$https://cdn.example.com/ep01.m3u8#第02集$https://cdn.example.com/ep02.m3u8"

        let sources = VODParser.parsePlaySources(from: playFrom, urlString: playUrl)
        XCTAssertEqual(sources.count, 1)

        let source = sources[0]
        XCTAssertEqual(source.name, "test_source")
        XCTAssertEqual(source.episodes.count, 2)

        XCTAssertEqual(source.episodes[0].name, "第01集")
        XCTAssertEqual(source.episodes[0].url.absoluteString, "https://cdn.example.com/ep01.m3u8")
        XCTAssertEqual(source.episodes[0].index, 1)

        XCTAssertEqual(source.episodes[1].name, "第02集")
        XCTAssertEqual(source.episodes[1].url.absoluteString, "https://cdn.example.com/ep02.m3u8")
        XCTAssertEqual(source.episodes[1].index, 2)
    }

    func testEpisodeURLRetainsDollarSignsAfterTitleSeparator() {
        let playURL = "正片$https://cdn.example.com/video.m3u8?token=first$second"

        let sources = VODParser.parsePlaySources(from: "test_source", urlString: playURL)

        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources[0].episodes.count, 1)
        XCTAssertEqual(
            sources[0].episodes[0].url.absoluteString,
            "https://cdn.example.com/video.m3u8?token=first$second"
        )
    }

    func testMultipleSources() {
        let playFrom = "高清播放源$$$备用极速源"
        let playUrl = "第1集$https://cdn1.com/1.m3u8#第2集$https://cdn1.com/2.m3u8$$$HD$https://cdn2.com/1.m3u8"

        let sources = VODParser.parsePlaySources(from: playFrom, urlString: playUrl)
        XCTAssertEqual(sources.count, 2)

        XCTAssertEqual(sources[0].name, "高清播放源")
        XCTAssertEqual(sources[0].episodes.count, 2)
        XCTAssertEqual(sources[0].episodes[0].name, "第1集")
        XCTAssertEqual(sources[0].episodes[1].name, "第2集")

        XCTAssertEqual(sources[1].name, "备用极速源")
        XCTAssertEqual(sources[1].episodes.count, 1)
        XCTAssertEqual(sources[1].episodes[0].name, "HD")
    }

    func testFallbackSourceNamesAndEpisodeNames() {
        // playFrom is nil, episodes don't have "$" separator
        let playUrl = "https://cdn.example.com/ep1.m3u8#https://cdn.example.com/ep2.m3u8"
        let sources = VODParser.parsePlaySources(from: nil, urlString: playUrl)

        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources[0].name, "Source 1")
        XCTAssertEqual(sources[0].episodes.count, 2)
        XCTAssertEqual(sources[0].episodes[0].name, "EP 1")
        XCTAssertEqual(sources[0].episodes[0].url.absoluteString, "https://cdn.example.com/ep1.m3u8")
    }

    func testEmptyAndMalformedStrings() {
        let emptySources = VODParser.parsePlaySources(from: "", urlString: "")
        XCTAssertTrue(emptySources.isEmpty)

        let nilSources = VODParser.parsePlaySources(from: nil, urlString: nil)
        XCTAssertTrue(nilSources.isEmpty)

        // Extra delimiters and invalid URLs
        let malformed = "###$$$###"
        let result = VODParser.parsePlaySources(from: "s1$$$s2", urlString: malformed)
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - JSON Decoding Tests with Mixed String/Int

    func testVODResponseFlexibleDecoding() throws {
        let json = """
        {
            "code": "1",
            "msg": "数据列表",
            "page": 2,
            "pagecount": "50",
            "limit": 20,
            "total": "1000",
            "class": [
                {
                    "type_id": 1,
                    "type_name": "电影",
                    "type_pid": "0"
                },
                {
                    "type_id": "2",
                    "type_name": "连续剧",
                    "type_pid": 0
                }
            ],
            "list": [
                {
                    "vod_id": 998877,
                    "vod_name": "流浪地球",
                    "type_id": 1,
                    "type_name": "科幻片",
                    "vod_pic": "https://img.example.com/pic.jpg",
                    "vod_remarks": "HD国语",
                    "vod_year": "2019",
                    "vod_area": "中国大陆",
                    "vod_actor": "吴京, 屈楚萧",
                    "vod_director": "郭帆",
                    "vod_content": "<p>近未来的地球面临绝境...&nbsp;</p>",
                    "vod_play_from": "lzm3u8",
                    "vod_play_url": "正片$https://cdn.example.com/wandering_earth.m3u8"
                }
            ]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(VODResponse.self, from: json)

        XCTAssertEqual(response.code?.value, 1)
        XCTAssertEqual(response.msg, "数据列表")
        XCTAssertEqual(response.page?.value, 2)
        XCTAssertEqual(response.pagecount?.value, 50)
        XCTAssertEqual(response.limit?.value, "20")
        XCTAssertEqual(response.total?.value, 1000)

        XCTAssertEqual(response.categories?.count, 2)
        XCTAssertEqual(response.categories?[0].id, "1")
        XCTAssertEqual(response.categories?[0].typeName, "电影")
        XCTAssertEqual(response.categories?[1].id, "2")

        XCTAssertEqual(response.list?.count, 1)
        let item = response.list![0]
        XCTAssertEqual(item.id, "998877")
        XCTAssertEqual(item.vodName, "流浪地球")
        XCTAssertEqual(item.vodYear, "2019")
        XCTAssertEqual(item.vodActor, "吴京, 屈楚萧")
        XCTAssertEqual(item.cleanSynopsis, "近未来的地球面临绝境...")

        XCTAssertEqual(item.playSources.count, 1)
        XCTAssertEqual(item.playSources[0].name, "lzm3u8")
        XCTAssertEqual(item.playSources[0].episodes.count, 1)
        XCTAssertEqual(item.playSources[0].episodes[0].name, "正片")
        XCTAssertEqual(item.playSources[0].episodes[0].url.absoluteString, "https://cdn.example.com/wandering_earth.m3u8")
    }
}
