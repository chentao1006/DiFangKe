import SwiftUI

struct MiniCalendarView: View {
    @Binding var selectedDate: Date
    @State private var currentMonth: Date
    let availableDates: Set<Date>
    let onDateSelected: (Date) -> Void
    
    private let calendar: Calendar = {
        var cal = Calendar.current
        cal.firstWeekday = 1
        return cal
    }()
    
    // Support long press repeat
    @State private var repeatTimer: Timer?
    @State private var repeatInterval: Double = 0.25
    @State private var isPressing = false
    
    private let daysInWeek = ["日", "一", "二", "三", "四", "五", "六"]
    
    // Strictly only show months that have footprints, plus the current month
    private var monthRange: [Date] {
        let today = Date()
        let currentMonthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: today))!
        
        // Extract all unique months from availableDates
        let monthsWithData = Set(availableDates.map { 
            calendar.date(from: calendar.dateComponents([.year, .month], from: $0))! 
        })
        
        // Combine with current month and sort
        let allMonths = monthsWithData.union([currentMonthStart])
        return allMonths.sorted()
    }
    
    init(selectedDate: Binding<Date>, availableDates: Set<Date>, onDateSelected: @escaping (Date) -> Void) {
        self._selectedDate = selectedDate
        self.availableDates = availableDates
        self.onDateSelected = onDateSelected
        
        let initialMonth = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: selectedDate.wrappedValue)) ?? 
                          Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date()))!
        self._currentMonth = State(initialValue: initialMonth)
    }
    
    var body: some View {
        VStack(spacing: 12) {
            // Header
            HStack {
                calendarArrow(direction: -1)
                
                Spacer()
                
                Text(currentMonth.formatted(.dateTime.year().month()))
                    .font(.system(.headline, design: .rounded))
                    .id(currentMonth)
                
                Spacer()
                
                calendarArrow(direction: 1)
            }
            .padding(.horizontal, 4)
            
            // Weekday labels
            HStack(spacing: 0) {
                ForEach(daysInWeek, id: \.self) { day in
                    Text(day)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.secondary.opacity(0.6))
                        .frame(maxWidth: .infinity)
                }
            }
            
            // Month Grid with Paging logic
            let range = monthRange
            if range.isEmpty {
                // Fallback for extreme cases
                Text("暂无数据")
                    .foregroundColor(.secondary)
                    .frame(height: 250)
            } else {
                TabView(selection: $currentMonth) {
                    ForEach(range, id: \.self) { month in
                        monthGridView(for: month)
                            .tag(month)
                            .padding(.horizontal, 4)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: 250)
                .onChange(of: currentMonth) { _, _ in
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(Color(uiColor: .systemBackground))
        )
        .frame(width: 300)
        .onDisappear {
            stopRepeat()
        }
    }
    
    @ViewBuilder
    private func calendarArrow(direction: Int) -> some View {
        let range = monthRange
        let currentIndex = range.firstIndex(of: currentMonth) ?? 0
        let targetIndex = currentIndex + direction
        let isDisabled = targetIndex < 0 || targetIndex >= range.count
        
        Image(systemName: direction == -1 ? "chevron.left" : "chevron.right")
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(isDisabled ? .secondary.opacity(0.2) : .secondary)
            .frame(width: 32, height: 32)
            .background(Circle().fill(Color.secondary.opacity(0.1)))
            .contentShape(Circle())
            .onLongPressGesture(minimumDuration: 0.3) {
                if !isDisabled {
                    startRepeat(direction: direction)
                }
            } onPressingChanged: { pressing in
                if !pressing {
                    stopRepeat()
                }
            }
            .onTapGesture {
                if !isDisabled {
                    changeMonth(by: direction)
                }
            }
    }
    
    @ViewBuilder
    private func monthGridView(for month: Date) -> some View {
        let days = daysInMonth(for: month)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 8) {
            ForEach(0..<days.count, id: \.self) { index in
                if let date = days[index] {
                    let startOfDay = calendar.startOfDay(for: date)
                    let isAvailable = availableDates.contains(startOfDay)
                    
                    MiniCalendarDayCell(
                        date: date,
                        isSelected: calendar.isDate(date, inSameDayAs: selectedDate),
                        isToday: calendar.isDateInToday(date),
                        isCurrentMonth: calendar.isDate(date, equalTo: month, toGranularity: .month),
                        isAvailable: isAvailable
                    )
                    .onTapGesture {
                        if isAvailable {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                selectedDate = date
                                onDateSelected(date)
                            }
                        }
                    }
                } else {
                    Color.clear.frame(height: 36)
                }
            }
        }
    }
    
    private func startRepeat(direction: Int) {
        stopRepeat()
        isPressing = true
        repeatInterval = 0.25
        
        triggerStep(direction: direction)
    }
    
    private func triggerStep(direction: Int) {
        guard isPressing else { return }
        
        let range = monthRange
        let currentIndex = range.firstIndex(of: currentMonth) ?? 0
        let targetIndex = currentIndex + direction
        
        if targetIndex >= 0 && targetIndex < range.count {
            changeMonth(by: direction)
            
            // Speed up
            repeatInterval = max(0.08, repeatInterval * 0.85)
            
            repeatTimer = Timer.scheduledTimer(withTimeInterval: repeatInterval, repeats: false) { _ in
                self.triggerStep(direction: direction)
            }
        } else {
            stopRepeat()
        }
    }
    
    private func stopRepeat() {
        isPressing = false
        repeatTimer?.invalidate()
        repeatTimer = nil
    }
    
    private func changeMonth(by amount: Int) {
        let range = monthRange
        guard let currentIndex = range.firstIndex(of: currentMonth) else { return }
        let targetIndex = currentIndex + amount
        
        if targetIndex >= 0 && targetIndex < range.count {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                currentMonth = range[targetIndex]
            }
        }
    }
    
    private func daysInMonth(for month: Date) -> [Date?] {
        guard let monthRange = calendar.range(of: .day, in: .month, for: month),
              let firstOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: month)) else {
            return []
        }
        
        let firstWeekday = calendar.component(.weekday, from: firstOfMonth)
        let offset = firstWeekday - 1
        
        var days: [Date?] = Array(repeating: nil, count: offset)
        
        for day in monthRange {
            if let date = calendar.date(byAdding: .day, value: day - 1, to: firstOfMonth) {
                days.append(date)
            }
        }
        
        return days
    }
}

private struct MiniCalendarDayCell: View {
    let date: Date
    let isSelected: Bool
    let isToday: Bool
    let isCurrentMonth: Bool
    let isAvailable: Bool
    
    private let calendar = Calendar.current
    
    var body: some View {
        Text("\(calendar.component(.day, from: date))")
            .font(.system(size: 15, weight: isSelected ? .bold : .medium, design: .rounded))
            .frame(width: 34, height: 34)
            .background(
                ZStack {
                    if isSelected {
                        Circle()
                            .fill(Color.dfkAccent)
                            .shadow(color: Color.dfkAccent.opacity(0.3), radius: 4, x: 0, y: 2)
                    } else if isToday {
                        Circle()
                            .stroke(Color.dfkAccent, lineWidth: 1.5)
                    }
                }
            )
            .foregroundColor(isSelected ? .white : 
                             (isAvailable ? 
                              (isToday ? .dfkAccent : (isCurrentMonth ? .primary : .secondary)) 
                              : .secondary.opacity(0.6)))
            .opacity(isAvailable ? 1.0 : 0.7)
            .contentShape(Circle())
    }
}
