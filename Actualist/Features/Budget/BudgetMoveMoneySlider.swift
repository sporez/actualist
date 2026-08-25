import SwiftUI

/// Slider range and detent for Move Money.
///
/// The track scales to 125% of the paying category's available amount so typical
/// moves use most of the bar and there is a little room past zero. Current is
/// only a floor, so a typed amount still fits. Never scale the current value —
/// that remaps a finger still on the thumb into a larger range and explodes.
/// A $10 floor only applies when there is no available amount and nothing has
/// been entered yet.
struct BudgetMoveMoneySliderMetrics: Equatable, Sendable {
    static let overshootMultiplierNumerator = 5
    static let overshootMultiplierDenominator = 4
    static let zeroAvailableMaximumAmount = 1_000

    static func maximumAmount(baselineAmount: Int, currentAmount: Int) -> Int {
        let scaledBaseline = scaledAmount(max(0, baselineAmount))
        let candidate = max(scaledBaseline, max(0, currentAmount))
        return candidate > 0 ? candidate : zeroAvailableMaximumAmount
    }

    static func scaledAmount(_ amount: Int) -> Int {
        let nonnegative = max(0, amount)
        let multiplied = nonnegative.multipliedReportingOverflow(by: overshootMultiplierNumerator)
        guard !multiplied.overflow else {
            return Int.max
        }

        let ceiled = multiplied.partialValue.addingReportingOverflow(overshootMultiplierDenominator - 1)
        guard !ceiled.overflow else {
            return Int.max
        }

        return ceiled.partialValue / overshootMultiplierDenominator
    }
}

enum BudgetMoveMoneyCoverIntro {
    static let startDelayNanoseconds: UInt64 = 280_000_000
    static let animationNanoseconds: UInt64 = 520_000_000
    static let stepCount = 20

    static func amount(progress: Double, target: Int) -> Int {
        guard target > 0 else {
            return 0
        }

        let clamped = min(max(progress, 0), 1)
        let value = (Double(target) * clamped).rounded()
        guard value.isFinite, value <= Double(Int.max) else {
            return target
        }
        return Int(value)
    }
}

struct BudgetMoveMoneySliderSpec: Equatable, Sendable {
    let amount: Int
    let detentAmount: Int
    let maximumAmount: Int
    var currency: BudgetCurrency = .usd

    var amountDollars: Double {
        currency.displayUnits(fromMinorUnits: amount)
    }

    var maximumDollars: Double {
        currency.displayUnits(fromMinorUnits: max(maximumAmount, 1))
    }

    var isOvershooting: Bool {
        detentAmount > 0 && amount > detentAmount
    }
}

struct BudgetMoveMoneySliderDetent: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case below
        case held
        case overshooting
    }

    private(set) var phase: Phase = .below
    private(set) var bumpCount = 0
    private(set) var isEditing = false
    private var sliderID: String?
    private var allowOvershootOnNextGesture = false

    mutating func reset() {
        self = BudgetMoveMoneySliderDetent(bumpCount: bumpCount)
    }

    mutating func registerLandingBump() {
        bumpCount += 1
    }

    mutating func beginEditing(sliderID: String, amount: Int, detentAmount: Int) {
        if self.sliderID != sliderID {
            resetForDifferentSlider()
            self.sliderID = sliderID
        }

        isEditing = true
        guard detentAmount > 0 else {
            phase = .below
            allowOvershootOnNextGesture = false
            return
        }

        if amount > detentAmount {
            phase = .overshooting
            allowOvershootOnNextGesture = false
            return
        }

        if amount == detentAmount && allowOvershootOnNextGesture {
            phase = .overshooting
            return
        }

        phase = amount == detentAmount ? .held : .below
    }

    mutating func endEditing(amount: Int, detentAmount: Int) {
        isEditing = false
        allowOvershootOnNextGesture = detentAmount > 0 && amount == detentAmount
        guard detentAmount > 0 else {
            phase = .below
            return
        }

        if amount > detentAmount {
            phase = .overshooting
        } else if amount == detentAmount {
            phase = .held
        } else {
            phase = .below
        }
    }

    mutating func apply(proposedAmount: Int, detentAmount: Int) -> Int {
        let proposed = max(0, proposedAmount)
        guard detentAmount > 0 else {
            phase = .below
            return proposed
        }

        guard isEditing else {
            if proposed > detentAmount {
                phase = .overshooting
            } else if proposed == detentAmount {
                phase = .held
            } else {
                phase = .below
            }
            return proposed
        }

        switch phase {
        case .overshooting:
            if proposed < detentAmount {
                phase = .below
                allowOvershootOnNextGesture = false
                return proposed
            }
            if proposed == detentAmount {
                phase = .held
            }
            return proposed

        case .held, .below:
            if proposed > detentAmount {
                if phase != .held {
                    bumpCount += 1
                }
                phase = .held
                return detentAmount
            }

            phase = proposed == detentAmount ? .held : .below
            if proposed < detentAmount {
                allowOvershootOnNextGesture = false
            }
            return proposed
        }
    }

    private mutating func resetForDifferentSlider() {
        phase = .below
        isEditing = false
        allowOvershootOnNextGesture = false
    }
}

/// Plays the detent tap immediately. SwiftUI `.sensoryFeedback` waits until
/// the slider gesture ends, so it felt like the end of the track instead of
/// the available-to-zero crossing.
struct BudgetMoveMoneyDetentHaptic: ViewModifier {
    let trigger: Int
    @State private var generator = UIImpactFeedbackGenerator(style: .rigid)

    func body(content: Content) -> some View {
        content
            .onAppear {
                generator.prepare()
            }
            .onChange(of: trigger) { old, new in
                guard new > old else {
                    return
                }
                generator.impactOccurred(intensity: 1)
                generator.prepare()
            }
    }
}

struct BudgetMoveMoneyAmountSlider: View {
    let spec: BudgetMoveMoneySliderSpec
    let isDisabled: Bool
    var onEditingChanged: (Bool) -> Void = { _ in }
    let onAmountDollarsChanged: (Double) -> Void
    @Environment(\.budgetCurrency) private var currency

    var body: some View {
        Slider(
            value: Binding(
                get: { spec.amountDollars },
                set: onAmountDollarsChanged
            ),
            in: 0...spec.maximumDollars
        ) { isEditing in
            onEditingChanged(isEditing)
        }
        .tint(spec.isOvershooting ? ActualistTheme.danger : ActualistTheme.accent)
        .disabled(isDisabled)
        .accessibilityValue(
            spec.isOvershooting
                ? "\(currency.formatted(spec.amount)), past available"
                : currency.formatted(spec.amount)
        )
    }
}
