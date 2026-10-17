import SwiftUI
import UIKit

/// Multi-touch piano keyboard. Velocity follows the vertical touch position
/// (further down the key = louder), sliding across keys plays glissandi.
final class KeyboardUIView: UIView {
    var baseNote = 48 { didSet { if baseNote != oldValue { releaseAll(); setNeedsDisplay() } } }
    var onNoteOn: ((Int, Int) -> Void)?
    var onNoteOff: ((Int) -> Void)?

    private var touchNotes: [ObjectIdentifier: Int] = [:]
    private var pressed: [Int: Int] = [:] // note -> touch count

    private static let whiteSemitones = [0, 2, 4, 5, 7, 9, 11]
    private static let hasBlackAfter: Set<Int> = [0, 1, 3, 4, 5] // C D F G A (white index in octave)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isOpaque = true
        backgroundColor = .black
        contentMode = .redraw
        isAccessibilityElement = true
        accessibilityLabel = "Keyboard"
        accessibilityTraits = .allowsDirectInteraction
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var whiteCount: Int { max(8, Int(bounds.width / 42)) }
    private var whiteWidth: CGFloat { bounds.width / CGFloat(whiteCount) }
    private var blackHeight: CGFloat { bounds.height * 0.6 }
    private var blackWidth: CGFloat { whiteWidth * 0.62 }

    private func whiteNote(_ index: Int) -> Int {
        baseNote + (index / 7) * 12 + KeyboardUIView.whiteSemitones[index % 7]
    }

    private func blackRect(afterWhite index: Int) -> CGRect? {
        guard KeyboardUIView.hasBlackAfter.contains(index % 7), index < whiteCount - 1 else { return nil }
        let x = CGFloat(index + 1) * whiteWidth - blackWidth / 2
        return CGRect(x: x, y: 0, width: blackWidth, height: blackHeight)
    }

    private func noteAt(_ point: CGPoint) -> (note: Int, velocity: Int)? {
        guard bounds.contains(point) else { return nil }
        if point.y < blackHeight {
            for i in 0..<whiteCount {
                if let r = blackRect(afterWhite: i), r.contains(point) {
                    let v = 40 + Int(87 * point.y / blackHeight)
                    return (whiteNote(i) + 1, min(127, v))
                }
            }
        }
        let i = min(whiteCount - 1, max(0, Int(point.x / whiteWidth)))
        let v = 40 + Int(87 * point.y / bounds.height)
        return (whiteNote(i), min(127, v))
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let accent = UIColor(red: 1.0, green: 0.48, blue: 0.10, alpha: 1)

        for i in 0..<whiteCount {
            let r = CGRect(x: CGFloat(i) * whiteWidth, y: 0, width: whiteWidth, height: bounds.height)
                .insetBy(dx: 0.75, dy: 0)
            let note = whiteNote(i)
            ctx.setFillColor((pressed[note] != nil ? accent : UIColor(white: 0.94, alpha: 1)).cgColor)
            ctx.addPath(UIBezierPath(roundedRect: r, byRoundingCorners: [.bottomLeft, .bottomRight],
                                     cornerRadii: CGSize(width: 4, height: 4)).cgPath)
            ctx.fillPath()
            if note % 12 == 0 {
                let label = "C\(note / 12 - 1)" as NSString
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 9, weight: .semibold),
                    .foregroundColor: UIColor(white: 0.45, alpha: 1),
                ]
                let size = label.size(withAttributes: attrs)
                label.draw(at: CGPoint(x: r.midX - size.width / 2, y: r.maxY - size.height - 4), withAttributes: attrs)
            }
        }
        for i in 0..<whiteCount {
            guard let r = blackRect(afterWhite: i) else { continue }
            let note = whiteNote(i) + 1
            ctx.setFillColor((pressed[note] != nil ? accent : UIColor(white: 0.1, alpha: 1)).cgColor)
            ctx.addPath(UIBezierPath(roundedRect: r, byRoundingCorners: [.bottomLeft, .bottomRight],
                                     cornerRadii: CGSize(width: 3, height: 3)).cgPath)
            ctx.fillPath()
        }
    }

    private func press(_ note: Int, velocity: Int) {
        pressed[note, default: 0] += 1
        if pressed[note] == 1 { onNoteOn?(note, velocity) }
        setNeedsDisplay()
    }

    private func release(_ note: Int) {
        guard let count = pressed[note] else { return }
        if count <= 1 {
            pressed.removeValue(forKey: note)
            onNoteOff?(note)
        } else {
            pressed[note] = count - 1
        }
        setNeedsDisplay()
    }

    func releaseAll() {
        for note in pressed.keys { onNoteOff?(note) }
        pressed.removeAll()
        touchNotes.removeAll()
        setNeedsDisplay()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            guard let hit = noteAt(t.location(in: self)) else { continue }
            touchNotes[ObjectIdentifier(t)] = hit.note
            press(hit.note, velocity: hit.velocity)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let id = ObjectIdentifier(t)
            let hit = noteAt(t.location(in: self))
            let old = touchNotes[id]
            if hit?.note == old { continue }
            if let old { release(old) }
            if let hit {
                touchNotes[id] = hit.note
                press(hit.note, velocity: hit.velocity)
            } else {
                touchNotes.removeValue(forKey: id)
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            if let note = touchNotes.removeValue(forKey: ObjectIdentifier(t)) { release(note) }
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }
}

struct KeyboardView: UIViewRepresentable {
    let baseNote: Int
    let onNoteOn: (Int, Int) -> Void
    let onNoteOff: (Int) -> Void

    func makeUIView(context: Context) -> KeyboardUIView {
        let view = KeyboardUIView()
        view.baseNote = baseNote
        view.onNoteOn = onNoteOn
        view.onNoteOff = onNoteOff
        return view
    }

    func updateUIView(_ view: KeyboardUIView, context: Context) {
        view.onNoteOn = onNoteOn
        view.onNoteOff = onNoteOff
        view.baseNote = baseNote
    }

    static func dismantleUIView(_ view: KeyboardUIView, coordinator: ()) {
        view.releaseAll()
    }
}
