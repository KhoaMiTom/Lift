import HealthKit

/// Today's numbers from Apple Health. Apple Watch data reaches the iPhone's Health store by itself, so no watch app is needed.
enum Health {
    private static let store = HKHealthStore()
    private static let bpm = HKUnit.count().unitDivided(by: .minute())

    static func summary() async throws -> [String: Any] {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw NSError(domain: "Lift", code: 1, userInfo: [NSLocalizedDescriptionKey: "Health data is not available on this device."])
        }
        let read: Set<HKObjectType> = [
            HKQuantityType(.stepCount), HKQuantityType(.activeEnergyBurned), HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.restingHeartRate), HKCategoryType(.sleepAnalysis),
        ]
        try await store.requestAuthorization(toShare: [], read: read)
        let start = Calendar.current.startOfDay(for: Date())
        // Read access is private: a denied type looks the same as "no data", so missing values just stay out of the result.
        return [
            "steps": await sum(.stepCount, .count(), start),
            "energy": await sum(.activeEnergyBurned, .kilocalorie(), start),
            "distance": await sum(.distanceWalkingRunning, .meter(), start),
            "restingHR": await latest(.restingHeartRate, bpm),
            "sleep": await sleep(start),
        ].compactMapValues { $0 }
    }

    private static func sum(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit, _ start: Date) async -> Double? {
        await withCheckedContinuation { c in
            let p = HKQuery.predicateForSamples(withStart: start, end: nil)
            store.execute(HKStatisticsQuery(quantityType: HKQuantityType(id), quantitySamplePredicate: p, options: .cumulativeSum) { _, s, _ in
                c.resume(returning: s?.sumQuantity()?.doubleValue(for: unit))
            })
        }
    }

    private static func latest(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit) async -> Double? {
        await withCheckedContinuation { c in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
            store.execute(HKSampleQuery(sampleType: HKQuantityType(id), predicate: nil, limit: 1, sortDescriptors: [sort]) { _, r, _ in
                c.resume(returning: (r?.first as? HKQuantitySample)?.quantity.doubleValue(for: unit))
            })
        }
    }

    /// Seconds asleep since 18:00 yesterday. Watch and phone can both log the same night, so overlapping samples are counted once.
    private static func sleep(_ midnight: Date) async -> Double? {
        let from = midnight.addingTimeInterval(-6 * 3600)
        let asleep = Set(HKCategoryValueSleepAnalysis.allAsleepValues.map(\.rawValue))
        return await withCheckedContinuation { c in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            let p = HKQuery.predicateForSamples(withStart: from, end: nil)
            store.execute(HKSampleQuery(sampleType: HKCategoryType(.sleepAnalysis), predicate: p, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, r, _ in
                var total = 0.0, covered = Date.distantPast
                for s in (r as? [HKCategorySample] ?? []) where asleep.contains(s.value) {
                    let begin = max(s.startDate, covered)
                    if s.endDate > begin { total += s.endDate.timeIntervalSince(begin); covered = s.endDate }
                }
                c.resume(returning: total > 0 ? total : nil)
            })
        }
    }
}
