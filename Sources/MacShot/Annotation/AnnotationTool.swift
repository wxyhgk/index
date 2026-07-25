import Foundation

enum AnnotationTool: CaseIterable {
    case rect
    case ellipse
    case arrow
    case text
    case highlight
    case pixelate

    var layerKind: Layer.Kind {
        switch self {
        case .rect: return .rect
        case .ellipse: return .ellipse
        case .arrow: return .arrow
        case .text: return .text
        case .highlight: return .highlight
        case .pixelate: return .pixelate
        }
    }

    var symbolName: String { layerKind.symbolName }
    var title: String { layerKind.displayName }
}
