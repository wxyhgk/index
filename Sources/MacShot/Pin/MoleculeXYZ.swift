import Foundation

/// 经过校验并规范化的 XYZ 分子文档。
///
/// Web 渲染器只接收这里重新生成的文本，不直接执行或插入剪贴板原文。
struct MoleculeXYZ: Equatable, Sendable {
    struct Atom: Equatable, Sendable {
        let element: String
        let x: Double
        let y: Double
        let z: Double
    }

    static let maximumAtomCount = 20_000

    let atoms: [Atom]
    let comment: String

    var atomCount: Int { atoms.count }

    /// 交给 3Dmol.js 的标准 XYZ 文本。数值用 POSIX locale，避免系统区域设置
    /// 把小数点变成逗号；注释只保留单行，剪贴板原文不会进入 HTML。
    var canonicalText: String {
        let atomLines = atoms.map { atom in
            String(
                format: "%@ %.12g %.12g %.12g",
                locale: Locale(identifier: "en_US_POSIX"),
                atom.element, atom.x, atom.y, atom.z
            )
        }
        return ([String(atomCount), comment] + atomLines).joined(separator: "\n") + "\n"
    }

    static func parse(_ source: String) throws -> MoleculeXYZ {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        while lines.first?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            lines.removeFirst()
        }
        while lines.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            lines.removeLast()
        }
        guard !lines.isEmpty else { throw ParseError.empty }

        if let declaredCount = Int(lines[0].trimmingCharacters(in: .whitespaces)),
           lines[0].trimmingCharacters(in: .whitespaces).allSatisfy({ $0.isNumber }) {
            return try parseStandard(lines: lines, declaredCount: declaredCount)
        }

        let atomLines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let atoms = try parseAtoms(atomLines)
        return MoleculeXYZ(atoms: atoms, comment: "Index clipboard molecule")
    }

    private static func parseStandard(lines: [String], declaredCount: Int) throws -> MoleculeXYZ {
        try validateCount(declaredCount)
        let remainder = Array(lines.dropFirst())

        // 标准 XYZ 的第二行是注释；也兼容常见的“省略空注释行”文本片段。
        let nonEmptyRemainder = remainder.filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        let comment: String
        let atomLines: [String]
        if nonEmptyRemainder.count == declaredCount {
            comment = "Index clipboard molecule"
            atomLines = nonEmptyRemainder
        } else {
            guard let commentLine = remainder.first else {
                throw ParseError.atomCount(expected: declaredCount, actual: 0)
            }
            comment = sanitizedComment(commentLine)
            atomLines = remainder.dropFirst().filter {
                !$0.trimmingCharacters(in: .whitespaces).isEmpty
            }
        }

        guard atomLines.count == declaredCount else {
            throw ParseError.atomCount(expected: declaredCount, actual: atomLines.count)
        }
        return MoleculeXYZ(atoms: try parseAtoms(atomLines), comment: comment)
    }

    private static func parseAtoms(_ lines: [String]) throws -> [Atom] {
        try validateCount(lines.count)
        return try lines.enumerated().map { index, line in
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard fields.count >= 4 else { throw ParseError.invalidAtomLine(index + 1) }

            let element = normalizedElement(String(fields[0]))
            guard periodicElements.contains(element) else {
                throw ParseError.invalidElement(String(fields[0]), line: index + 1)
            }
            guard
                let x = Double(fields[1]), x.isFinite,
                let y = Double(fields[2]), y.isFinite,
                let z = Double(fields[3]), z.isFinite
            else {
                throw ParseError.invalidCoordinate(index + 1)
            }
            return Atom(element: element, x: x, y: y, z: z)
        }
    }

    private static func validateCount(_ count: Int) throws {
        guard count > 0 else { throw ParseError.empty }
        guard count <= maximumAtomCount else {
            throw ParseError.tooManyAtoms(maximum: maximumAtomCount)
        }
    }

    private static func sanitizedComment(_ source: String) -> String {
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "Index clipboard molecule" : String(value.prefix(200))
    }

    private static func normalizedElement(_ source: String) -> String {
        guard let first = source.first else { return source }
        return String(first).uppercased() + source.dropFirst().lowercased()
    }

    private static let periodicElements: Set<String> = [
        "H", "He", "Li", "Be", "B", "C", "N", "O", "F", "Ne",
        "Na", "Mg", "Al", "Si", "P", "S", "Cl", "Ar", "K", "Ca",
        "Sc", "Ti", "V", "Cr", "Mn", "Fe", "Co", "Ni", "Cu", "Zn",
        "Ga", "Ge", "As", "Se", "Br", "Kr", "Rb", "Sr", "Y", "Zr",
        "Nb", "Mo", "Tc", "Ru", "Rh", "Pd", "Ag", "Cd", "In", "Sn",
        "Sb", "Te", "I", "Xe", "Cs", "Ba", "La", "Ce", "Pr", "Nd",
        "Pm", "Sm", "Eu", "Gd", "Tb", "Dy", "Ho", "Er", "Tm", "Yb",
        "Lu", "Hf", "Ta", "W", "Re", "Os", "Ir", "Pt", "Au", "Hg",
        "Tl", "Pb", "Bi", "Po", "At", "Rn", "Fr", "Ra", "Ac", "Th",
        "Pa", "U", "Np", "Pu", "Am", "Cm", "Bk", "Cf", "Es", "Fm",
        "Md", "No", "Lr", "Rf", "Db", "Sg", "Bh", "Hs", "Mt", "Ds",
        "Rg", "Cn", "Nh", "Fl", "Mc", "Lv", "Ts", "Og"
    ]
}

extension MoleculeXYZ {
    enum ParseError: LocalizedError, Equatable {
        case empty
        case atomCount(expected: Int, actual: Int)
        case invalidAtomLine(Int)
        case invalidElement(String, line: Int)
        case invalidCoordinate(Int)
        case tooManyAtoms(maximum: Int)

        var errorDescription: String? {
            switch self {
            case .empty:
                return "剪贴板里没有可识别的 XYZ 坐标。"
            case let .atomCount(expected, actual):
                return "XYZ 声明了 \(expected) 个原子，但实际读取到 \(actual) 行坐标。"
            case let .invalidAtomLine(line):
                return "第 \(line) 行不是“元素 X Y Z”格式。"
            case let .invalidElement(element, line):
                return "第 \(line) 行的元素符号“\(element)”无法识别。"
            case let .invalidCoordinate(line):
                return "第 \(line) 行包含无效坐标。"
            case let .tooManyAtoms(maximum):
                return "原子数超过当前上限 \(maximum)。"
            }
        }
    }
}
