import Foundation
import Testing
@testable import strius

@MainActor
struct WorkbookDecodingTests {
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    @Test
    func decodeHomeWithSubunitAndCapture() throws {
        let json = """
        {"now":[{"id":"s1","unit_id":"u1","unit_title":"線形代数","title":"実対称行列の直交対角化","outcome":"","position":0,
          "stage":4,"stage_label":"練習","status":"active","n":10,"threshold":0.8,"scoring_unit":"問",
          "window":{"n":10,"threshold":0.8,"count":1,"correct":0,"score":0.0,"passed":false,"required_correct":8},
          "tiles":[{"id":"p1","position":0,"prompt":"行列 A の固有値を求めよ","source":"capture","state":"wrong","attempt_count":1,
            "assisted":false,"error_tag":"符号ミス","hint_given":false,"last_attempt_at":"2026-09-16T07:48:00+00:00"}],
          "open_set_id":null,"last_result":null,"can_advance":false,"updated_at":"2026-09-16T07:48:00+00:00"}],
         "recent":[{"id":"c1","status":"graded","created_at":"2026-09-16T07:47:00+00:00","graded_at":"2026-09-16T07:48:00+00:00",
          "subunit_id":"s1","subunit_title":"実対称行列の直交対角化","unit_id":"u1","unit_title":"線形代数","set_id":null,
          "verdicts":[{"problem_id":"p1","label":"1","prompt_text":"行列 A","verdict":"wrong","error_tag":"符号ミス","note":"符号を確認"}],
          "summary":{"correct":0,"total":1,"score":0.0,"passed":false,"note":""},"candidates":[],"next_set_id":null,
          "outcome":"new_unit","error":null,"image_path":"/v1/captures/c1/image"}],
         "units":[],"triage_count":0}
        """
        let home = try Self.decoder.decode(WorkbookHomeDTO.self, from: Data(json.utf8))
        let subunit = try #require(home.now.first)
        #expect(subunit.stageValue == .practice)
        #expect(subunit.stageValue.isModelWork == false)
        #expect(subunit.window.requiredCorrect == 8)
        #expect(subunit.tiles.first?.state == .wrong)
        let capture = try #require(home.recent.first)
        #expect(capture.status == .graded)
        #expect(capture.verdicts.first?.errorTag == "符号ミス")
        #expect(capture.outcome == "new_unit")
    }

    @Test
    func decodeSetAndProposal() throws {
        let setJSON = """
        {"id":"set1","subunit_id":"s1","stage":4,"stage_label":"練習","kind":"practice","status":"generating",
         "problems":[],"gate":{"count":10},"result":null,"error":null,"created_at":"2026-09-16T07:50:00+00:00"}
        """
        let set = try Self.decoder.decode(WorkbookSetDTO.self, from: Data(setJSON.utf8))
        #expect(set.kind == .practice && set.status == .generating)

        let proposalJSON = """
        {"id":"pr1","status":"ready","request":"二次関数","overview":{"unit_title":"二次関数の基礎","outcome":"",
          "subunits":[{"title":"頂点の座標が求められる","outcome":"","n":5,"scoring_unit":"問"}]},
         "unit_id":null,"thread_id":null,"message_id":"m1","error":null,"created_at":"2026-09-16T07:50:00+00:00"}
        """
        let proposal = try Self.decoder.decode(WorkbookProposalDTO.self, from: Data(proposalJSON.utf8))
        #expect(proposal.overview?.subunits.count == 1)
        #expect(proposal.status == .ready)
    }

    @Test
    func workbookViewRefEncodesSnakeCase() {
        let ref = WorkbookViewRef(subunitId: "s1", setId: nil)
        #expect(ref.jsonString.contains("\"subunit_id\":\"s1\""))
        #expect(!ref.jsonString.contains("setId"))
    }

    @Test
    func endpointsFollowTheWorkbookContract() {
        #expect(APIEndpoint.workbookHome.path == "/v1/workbook/home")
        #expect(APIEndpoint.workbookAdvance(subunitID: "s1").method == .post)
        #expect(APIEndpoint.workbookAdvance(subunitID: "s1").path == "/v1/subunits/s1/advance")
        #expect(APIEndpoint.workbookCreateSet(subunitID: "s1").path == "/v1/subunits/s1/sets")
        #expect(APIEndpoint.workbookCreateCapture.path == "/v1/captures")
        #expect(APIEndpoint.workbookCaptureUploadPrefix == "/v1/captures")
        #expect(APIEndpoint.workbookAssign(captureID: "c1").path == "/v1/captures/c1/assign")
        #expect(APIEndpoint.workbookStartProposal(id: "p1").path == "/v1/workbook/proposals/p1/start")
        #expect(APIEndpoint.workbookCaptures(only: "triage").queryItems.contains { $0.name == "only" && $0.value == "triage" })
    }

    @Test
    func realtimeWorkbookEventsDecode() {
        let text = """
        {"type":"workbook.capture.updated","user_id":"u","data":{"capture_id":"c1","status":"graded"},"created_at":"2026-09-16T07:48:00Z"}
        """
        #expect(RealtimeEvent.decode(from: text) == .workbookCaptureUpdated(captureID: "c1", status: "graded"))
    }
}
