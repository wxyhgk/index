import Foundation
import CoreGraphics

/// 图层坐标所处的空间。用 phantom type 标记，让「忘了换算」变成编译错误。
///
/// 此前同一个 `[Layer]` 承载三种互不兼容的语义（显示器局部点 / 图片像素 /
/// 已换算的裁剪图像素），换算只发生在一个调用点。忘调用或调用两次，
/// 编译器一声不吭，用户看到的是标注错位 —— 这是整个代码库最脆的地方。
protocol LayerSpace {}

/// 画布空间：标注**编辑时**的工作坐标系，左上原点、Y 向下。
/// 单位随画布而定 —— 截图覆盖层是显示器局部的点，钉图窗口是图片像素。
enum CanvasSpace: LayerSpace {}

/// 图像像素空间：左上原点、单位是目标图片的像素。
/// **入库和导出只接受这个空间**。
enum ImageSpace: LayerSpace {}

/// 带空间标记的图层集合。
struct Layers<Space: LayerSpace>: Equatable {

    private(set) var elements: [Layer]

    init(_ elements: [Layer] = []) {
        self.elements = elements
    }

    var isEmpty: Bool { elements.isEmpty }
    var count: Int { elements.count }

    mutating func append(_ layer: Layer) { elements.append(layer) }

    /// 按指定位置插回（撤销删除时恢复图层的叠放次序用）。越界时收敛到末尾。
    mutating func insert(_ layer: Layer, at index: Int) {
        elements.insert(layer, at: min(max(index, 0), elements.count))
    }

    @discardableResult
    mutating func removeLast() -> Layer? { elements.popLast() }

    mutating func removeAll() { elements.removeAll() }

    mutating func remove(id: UUID) {
        elements.removeAll { $0.id == id }
    }

    func firstIndex(id: UUID) -> Int? {
        elements.firstIndex { $0.id == id }
    }

    subscript(index: Int) -> Layer {
        get { elements[index] }
        set { elements[index] = newValue }
    }

    func filter(_ isIncluded: (Layer) -> Bool) -> Layers<Space> {
        Layers(elements.filter(isIncluded))
    }

    static func + (lhs: Layers<Space>, rhs: Layers<Space>) -> Layers<Space> {
        Layers(lhs.elements + rhs.elements)
    }
}

extension Layers where Space == ImageSpace {
    /// 从持久化的裸数组构造。数据库里存的一律是图像像素空间。
    init(persisted elements: [Layer]) {
        self.init(elements)
    }

    var persisted: [Layer] { elements }
}

extension Layers where Space == CanvasSpace {

    /// 画布空间 → 图像像素空间。**唯一的桥**。
    ///
    /// - Parameters:
    ///   - selection: 选区在画布空间中的位置。钉图窗口的画布本身就是整张图，传 `.zero` 起点。
    ///   - scale: 画布单位到图像像素的倍率。钉图窗口画布已是像素，传 1。
    func projected(onto selection: CGRect, scale: CGFloat) -> Layers<ImageSpace> {
        Layers<ImageSpace>(elements.map { layer in
            var copy = layer
            copy.rect = LRect(
                x: (layer.rect.x - selection.minX) * scale,
                y: (layer.rect.y - selection.minY) * scale,
                w: layer.rect.w * scale,
                h: layer.rect.h * scale
            )
            copy.lineWidth = layer.lineWidth * scale
            copy.fontSize = layer.fontSize * scale
            return copy
        })
    }
}
