import Foundation
import FoundationModels

/// Apple's on-device language model (Foundation Models, iOS 26) as the coach
/// (owner 2026-09-27: "if we can switch to Apple's on device model then yes").
/// It runs on the iPhone with no network and no key. Every reply is audited
/// against the numbers Atria actually sent (`fabricationFlags`); a reply that
/// invents a figure is never shown — the deterministic template answer is.
enum AtriaOnDeviceModel {
    enum Status: Equatable {
        case available
        case appleIntelligenceOff
        case deviceNotEligible
        case modelNotReady
        case unavailable

        /// One short line for Settings and the coach card.
        var detail: String {
            switch self {
            case .available: return "Apple Intelligence, on this iPhone"
            case .appleIntelligenceOff: return "Turn on Apple Intelligence in Settings to use it"
            case .deviceNotEligible: return "This iPhone can't run Apple Intelligence"
            case .modelNotReady: return "Apple Intelligence is still downloading"
            case .unavailable: return "Apple Intelligence isn't available right now"
            }
        }
    }

    static var status: Status {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(.appleIntelligenceNotEnabled):
            return .appleIntelligenceOff
        case .unavailable(.deviceNotEligible):
            return .deviceNotEligible
        case .unavailable(.modelNotReady):
            return .modelNotReady
        case .unavailable:
            return .unavailable
        }
    }

    static var isAvailable: Bool { status == .available }

    /// Style rules on top of the pinned DATA-only prompt.
    static func instructions(for payload: AtriaCoachPayload) -> String {
        AtriaCoachProviderRequestBuilder.systemPrompt(for: payload) + """
         You are Atria's coach. Use plain, friendly words. Keep it short: at \
        most three sentences. Only use numbers that appear in DATA, written the \
        same way, as digits (write 38%, never thirty-eight). Never diagnose, never give medical advice, never mention \
        being an AI.
        """
    }

    /// DATA as short readable lines (the on-device context is small, and the
    /// model quoted raw JSON seconds as "1122.5 seconds" on device 2026-09-27).
    static func dataBlock(for payload: AtriaCoachPayload) -> String {
        var lines = ["DATA", "Now: \(payload.now)"]
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE MMM d")
        let days = payload.last7.isEmpty ? payload.today.map { [$0] } ?? [] : payload.last7
        for day in days.sorted(by: { $0.day < $1.day }) {
            var parts: [String] = []
            if let recovery = day.recovery { parts.append("recovery \(recovery)%") }
            if let seconds = day.sleepSeconds, seconds > 0 {
                let minutes = Int((seconds / 60).rounded())
                parts.append("sleep \(minutes / 60)h \(minutes % 60)m")
            }
            if let performance = day.sleepPerformance { parts.append("sleep performance \(performance)%") }
            if let lnRMSSD = day.lnRMSSD { parts.append("HRV \(Int(exp(lnRMSSD).rounded())) ms") }
            if let rhr = day.rhr { parts.append("resting HR \(rhr) bpm") }
            if let strain = day.strain { parts.append(String(format: "strain %.1f", strain)) }
            if let respiratory = day.respiratoryRate { parts.append(String(format: "breathing %.1f per min", respiratory)) }
            let label = day == payload.today ? "Today (\(formatter.string(from: day.day)))" : formatter.string(from: day.day)
            lines.append("\(label): \(parts.isEmpty ? "no data" : parts.joined(separator: ", "))")
        }
        for key in payload.baselines.keys.sorted() {
            guard let range = payload.baselines[key], let low = range.low, let high = range.high else { continue }
            lines.append(String(format: "Usual %@: %.0f to %.0f", key, low, high))
        }
        return lines.joined(separator: "\n")
    }

    /// Spelled-out numbers dodge the figure audit ("thirty-eight" on device
    /// 2026-09-27), so a reply that uses them is never shown.
    static func spellsOutNumbers(_ text: String) -> Bool {
        let words = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
                     "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen",
                     "eighteen", "nineteen", "twenty", "thirty", "forty", "fifty", "sixty", "seventy",
                     "eighty", "ninety", "hundred", "thousand"]
        let tokens = text.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
        // "one" alone is ordinary English ("one thing"); anything else counts.
        return tokens.contains { $0 != "one" && words.contains($0) }
    }

    /// Passes only replies whose every figure is in DATA, written as digits.
    static func passesAudit(_ reply: String, payload: AtriaCoachPayload) -> Bool {
        AtriaCoachPayload.fabricationFlags(response: reply, payload: payload).isEmpty
            && !spellsOutNumbers(reply)
    }

    /// A model reply split into the card's title and detail.
    static func splitTitle(_ text: String) -> (title: String, detail: String) {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#*").union(.whitespaces)) }
            .filter { !$0.isEmpty }
        guard let first = lines.first else { return ("", "") }
        guard lines.count > 1 else { return ("", first) }
        return (first, lines.dropFirst().joined(separator: " "))
    }

    static func respond(instructions: String, prompt: String) async -> String? {
        guard isAvailable else { return nil }
        let session = LanguageModelSession(instructions: instructions)
        do {
            let response = try await session.respond(
                to: prompt,
                options: GenerationOptions(temperature: 0.3, maximumResponseTokens: 220)
            )
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            AtriaDebugLog("ATRIADBG coach status=on_device_failed error=%@", String(describing: error))
            return nil
        }
    }

    /// A free-form question answered only from DATA. Nil when the model is
    /// unavailable, fails, or invents a figure — callers then say so plainly.
    static func answer(question: String, payload: AtriaCoachPayload) async -> String? {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let prompt = "\(dataBlock(for: payload))\n\nQuestion: \(trimmed)"
        guard let reply = await respond(instructions: instructions(for: payload), prompt: prompt),
              passesAudit(reply, payload: payload) else {
            return nil
        }
        return reply
    }
}

/// On-device mode: Apple's model when it is available, the deterministic
/// template otherwise (or when the model's reply fails the figure audit).
struct AtriaOnDeviceCoachProvider: AtriaCoachProvider {
    let networkPolicy: AtriaCoachNetworkPolicy = .offlineOnly

    func answer(payload: AtriaCoachPayload, context: AtriaCoachContext) async -> AtriaCoachAnswer {
        let template = await AtriaLocalCoachProvider().answer(payload: payload, context: context)
        let prompt = """
        \(AtriaOnDeviceModel.dataBlock(for: payload))

        Today in Atria's words: \(template.title). \(template.detail)

        Write today's summary. First line: a short plain-English headline of \
        at most six words, with no numbers, colons or metric names. Then one \
        or two sentences on what that means for today, using the numbers from \
        DATA where they help.
        """
        guard let reply = await AtriaOnDeviceModel.respond(
                instructions: AtriaOnDeviceModel.instructions(for: payload),
                prompt: prompt
              ),
              AtriaOnDeviceModel.passesAudit(reply, payload: payload) else {
            return template
        }
        let split = AtriaOnDeviceModel.splitTitle(reply)
        return AtriaCoachAnswer(
            title: split.title.isEmpty ? template.title : split.title,
            detail: split.detail,
            disclosure: "\(payload.receiptSummary). Written by Apple Intelligence on this iPhone. No data leaves it.",
            networkPolicy: networkPolicy
        )
    }
}
