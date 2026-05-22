import Foundation

let times = [0, 74*60, 75*60] // e.g. 9:08, 10:22, 10:23
var moveStartIndex = 0
for i in 1..<times.count {
    if times[i] - times[i-1] > 360 { // AppConfig.shared.stayDurationThreshold is 360
        moveStartIndex = i
    }
}
print(times[moveStartIndex])
