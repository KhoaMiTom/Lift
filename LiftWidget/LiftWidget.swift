import SwiftUI
import WidgetKit

// MARK: - Look: black with neon green, heavy italic numbers. It turns solid neon when you are checked in.

private let neon = Color(red: 0.843, green: 1.0, blue: 0.0)
private let ink = Color.black
private let white = Color.white
private let track = Color(red: 0.18, green: 0.18, blue: 0.19)

// MARK: - Dates

enum WidgetDay {
    private static let keyFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func key(_ date: Date) -> String { keyFormat.string(from: date) }
}

// MARK: - Timeline

struct LiftEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct LiftProvider: TimelineProvider {
    func placeholder(in context: Context) -> LiftEntry {
        LiftEntry(date: Date(), snapshot: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (LiftEntry) -> Void) {
        completion(LiftEntry(date: Date(), snapshot: context.isPreview ? .sample : WidgetStore.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LiftEntry>) -> Void) {
        let now = Date()
        let startOfToday = Calendar.current.startOfDay(for: now)
        let midnight = Calendar.current.date(byAdding: .day, value: 1, to: startOfToday) ?? now.addingTimeInterval(3600)
        let entry = LiftEntry(date: now, snapshot: WidgetStore.read())
        // The app reloads the widget on every change; this only rolls it over at midnight.
        completion(Timeline(entries: [entry], policy: .after(midnight)))
    }
}

// MARK: - Views

private extension View {
    @ViewBuilder
    func widgetBackground(_ color: Color) -> some View {
        if #available(iOS 17.0, *) {
            containerBackground(color, for: .widget)
        } else {
            background(color)
        }
    }
}

struct LiftWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: LiftEntry

    private var snap: WidgetSnapshot? { entry.snapshot }
    /// The snapshot is from today. After midnight it is stale until the app is opened again.
    private var fresh: Bool { snap?.date == WidgetDay.key(entry.date) }
    private var checkedIn: Bool { fresh && (snap?.checkedIn ?? false) }
    private var items: [WidgetSnapshot.Item] { fresh ? (snap?.items ?? []) : [] }
    private var doneCount: Int { items.filter { $0.done }.count }
    private var progress: Double { checkedIn ? 1 : (items.isEmpty ? 0 : Double(doneCount) / Double(items.count)) }

    private var status: String {
        if !fresh { return "Open Lift" }
        if checkedIn { return "Checked in" }
        if items.isEmpty { return "No plan yet" }
        return "\(items.count - doneCount) to go"
    }

    // Colors flip together with the background.
    private var main: Color { checkedIn ? ink : neon }
    private var text: Color { checkedIn ? ink : white }
    private var dim: Color { checkedIn ? ink.opacity(0.55) : Color(red: 0.66, green: 0.66, blue: 0.69) }
    private var rail: Color { checkedIn ? ink.opacity(0.18) : track }
    private var fill: Color { checkedIn ? ink : neon }

    var body: some View {
        Group {
            if snap == nil {
                empty
            } else if family == .systemSmall {
                small
            } else {
                medium
            }
        }
        .widgetBackground(checkedIn ? neon : ink)
    }

    // MARK: pieces

    private var empty: some View {
        Text("Open Lift")
            .font(.system(size: 22, weight: .black).italic())
            .foregroundColor(neon)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func count(_ size: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text("\(doneCount)")
                .font(.system(size: size, weight: .black).italic())
                .foregroundColor(main)
            if !items.isEmpty {
                Text("/\(items.count)")
                    .font(.system(size: size * 0.45, weight: .black).italic())
                    .foregroundColor(dim)
            }
        }
        .minimumScaleFactor(0.6)
        .lineLimit(1)
    }

    private var bar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(rail)
                Rectangle().fill(fill).frame(width: geo.size.width * CGFloat(min(max(progress, 0), 1)))
            }
        }
        .frame(height: 8)
    }

    private var statusText: some View {
        Text(status)
            .font(.system(size: 16, weight: .heavy))
            .foregroundColor(text)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    // MARK: layouts

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            count(64)
            Spacer(minLength: 6)
            statusText
            bar.padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 0) {
            count(88)
            Spacer(minLength: 6)
            statusText
            bar.padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Widget

@main
struct LiftWidget: Widget {
    let kind = "LiftWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LiftProvider()) { entry in
            LiftWidgetView(entry: entry)
        }
        .configurationDisplayName("Lift")
        .description("Check-in.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
