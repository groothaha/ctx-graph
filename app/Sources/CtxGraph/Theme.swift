import AppKit
import SwiftUI

/// 색 ("배선도"): 맥락은 카드의 핀에서 핀으로 직각 선을 따라 가고, 선 위 꺾쇠가 방향을 가리킨다.
/// 받은 선은 회색으로 조용하고, 기다리는 맥락만 노랗다. 바탕·카드 색은 캔버스에만 쓰고 창 틀(사이드바·메뉴·설정)은 macOS 기본.
/// 상태 색은 앱 어디서나 같은 뜻 — 다른 화면에서 시스템 주황·초록을 따로 쓰지 않는다:
///   노랑(flow)  = 움직이는 중: 맥락이 기다림·요약 중, Claude 가 답하는 중
///   빨강(fail)  = 고장·막힘: 실패, 키 없음, 폴더 없음 (경고도 여기 — 노랑과 헷갈리지 않게)
///   파랑(attention) = 안 읽은 알림.  선택은 밝은 제목 색 테두리
///   초록(ok)    = 방금 한 일이 됐다는 확인 (연결 시험 성공, 키 저장) — 상태 표시에는 안 씀
enum Ink {
    /// 캔버스 바닥 (청사진 판)
    static let basin = Color.dyn(0xF3F5F8, 0x0C1016)
    /// 격자: 24pt 가는 선, 120pt 마다 진한 선
    static let gridMinor = Color.dyn(0x2A4A7A, 0x78A0E6, la: 0.055, da: 0.04)
    static let gridMajor = Color.dyn(0x2A4A7A, 0x78A0E6, la: 0.11, da: 0.08)
    /// 카드
    static let card = Color.dyn(0xFFFFFF, 0x121923)
    static let cardHover = Color.dyn(0xFAFBFD, 0x16202C)
    /// 카드 테두리 (그림자 대신 얇은 선)
    static let ring = Color.dyn(0x1E3250, 0x8CAAD7, la: 0.16, da: 0.17)
    static let ringHover = Color.dyn(0x1E3250, 0x8CAAD7, la: 0.28, da: 0.30)
    /// 카드 제목 (선택 테두리도 이 색)
    static let title = Color.dyn(0x172130, 0xDCE5F2)
    /// 카드의 둘째 줄 (시간·요약 버전, 고정폭)
    static let meta = Color.dyn(0x5A6A80, 0x7E8DA3)
    /// 맥락이 기다리는·흐르는 선
    static let flow = Color.dyn(0xC98A12, 0xF4B54A)
    /// 맥락이 막 들어갈 때 선을 훑고 지나가는 밝은 물결
    static let flowBright = Color.dyn(0xFFE7A8, 0xFFF4D9)
    /// 흐름 색 글자 (밝은 바탕에서도 읽히게 더 진하게)
    static let flowText = Color.dyn(0x8A5A00, 0xF4B54A)
    /// 받은 선·아직 안 온 선 (회색 배선)
    static let pipe = Color.dyn(0xA8B3C2, 0x3A4A60)
    /// 실패·막힘
    static let fail = Color.dyn(0xD23C3C, 0xFF6D6D)
    /// 확인됨 (한 일의 결과에만)
    static let ok = Color.dyn(0x1F8A4C, 0x5BC98A)
    /// 안 읽은 알림 (터미널 테두리·카드 빛·탭 점)
    static let attention = Color(nsColor: .systemBlue)
}

extension Color {
    /// 밝은/어두운 화면에 따라 바뀌는 색 (0xRRGGBB)
    static func dyn(_ light: UInt32, _ dark: UInt32, la: CGFloat = 1, da: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { ap in
            let isDark = ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let v = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                           green: CGFloat((v >> 8) & 0xFF) / 255,
                           blue: CGFloat(v & 0xFF) / 255,
                           alpha: isDark ? da : la)
        })
    }
}

/// 움직임 줄이기 설정 (요약 중 흐름 애니메이션을 멈춘다)
@MainActor
enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

extension CGPoint {
    /// 가장 가까운 정수 pt (1배율 모니터에서 글자·선이 번지지 않게)
    var snapped: CGPoint { CGPoint(x: x.rounded(), y: y.rounded()) }
}

/// 앱이 고른 언어 (번들의 en·ko.lproj 와 macOS 언어 설정으로 정해짐). 백엔드(ctxgraph.py)에도 넘겨
/// 요약·주입 글·알림 문구를 같은 언어로 만든다.
enum AppLang {
    static let code: String = {
        let c = Bundle.main.preferredLocalizations.first ?? "en"
        return c.hasPrefix("ko") ? "ko" : "en"
    }()
    static var locale: Locale { Locale(identifier: code) }
}
