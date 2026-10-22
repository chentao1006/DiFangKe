package com.ct106.difangke.service

import android.content.Context
import androidx.work.*
import com.ct106.difangke.AppConfig
import com.ct106.difangke.data.db.AppDatabase
import com.ct106.difangke.data.db.entity.*
import com.ct106.difangke.data.prefs.AppPreferences
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import kotlinx.coroutines.yield
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.*
import java.util.concurrent.TimeUnit

class TripScanWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    companion object {
        private const val PERIODIC_NAME = "trip_history_scan"
        private const val IMMEDIATE_NAME = "trip_history_scan_now"
        private const val ONLY_MISSING_DATES = "only_missing_dates"

        fun schedule(context: Context, runNow: Boolean = false) {
            val constraints = Constraints.Builder().setRequiresBatteryNotLow(true).build()
            val periodic = PeriodicWorkRequestBuilder<TripScanWorker>(AppConfig.TRIP_SCAN_INTERVAL_HOURS, TimeUnit.HOURS)
                .setConstraints(constraints).build()
            WorkManager.getInstance(context).enqueueUniquePeriodicWork(PERIODIC_NAME, ExistingPeriodicWorkPolicy.UPDATE, periodic)
            if (runNow) {
                WorkManager.getInstance(context).enqueueUniqueWork(
                    IMMEDIATE_NAME,
                    ExistingWorkPolicy.KEEP,
                    OneTimeWorkRequestBuilder<TripScanWorker>().setConstraints(constraints).build()
                )
            }
        }

        fun cancel(context: Context) {
            WorkManager.getInstance(context).cancelUniqueWork(PERIODIC_NAME)
            WorkManager.getInstance(context).cancelUniqueWork(IMMEDIATE_NAME)
        }

        fun rescan(context: Context, onlyMissingDates: Boolean = false) {
            val constraints = Constraints.Builder().setRequiresBatteryNotLow(true).build()
            WorkManager.getInstance(context).enqueueUniqueWork(
                IMMEDIATE_NAME,
                ExistingWorkPolicy.REPLACE,
                OneTimeWorkRequestBuilder<TripScanWorker>()
                    .setConstraints(constraints)
                    .setInputData(workDataOf(ONLY_MISSING_DATES to onlyMissingDates))
                    .build()
            )
        }
    }

    override suspend fun doWork(): Result {
        val prefs = AppPreferences(applicationContext)
        if (!prefs.tripAutomaticRecognitionEnabled.first()) return Result.success()
        prefs.setTripScanRunning(true)
        return try {
            val db = AppDatabase.getInstance(applicationContext)
            db.tripDao().finalizeLegacyAutomaticDrafts()
            val onlyMissingDates = inputData.getBoolean(ONLY_MISSING_DATES, false)
            while (!isStopped && scanBatch(db, prefs, onlyMissingDates)) yield()
            Result.success()
        } catch (_: Throwable) {
            Result.retry()
        } finally {
            prefs.setTripScanRunning(false)
        }
    }

    private suspend fun scanBatch(db: AppDatabase, prefs: AppPreferences, onlyMissingDates: Boolean): Boolean = withContext(Dispatchers.IO) {
        val home = db.tripDao().getHomeCity() ?: return@withContext false
        val calendar = Calendar.getInstance()
        val today = startOfDay(Date())
        val first = db.footprintDao().getEarliest() ?: return@withContext false
        val start = Date(prefs.getTripScanCursor() ?: startOfDay(first.startTime).time)
        if (!start.before(today)) return@withContext false
        val end = Calendar.getInstance().apply {
            time = start
            add(Calendar.DAY_OF_YEAR, AppConfig.TRIP_SCAN_BATCH_DAYS)
        }.time.coerceAtMost(today)
        val footprints = db.footprintDao().getBetween(start, end)
        val existingTrips = if (onlyMissingDates) db.tripDao().getTrips() else emptyList()
        val suppressedRanges = decodeSuppressedRanges(prefs.getTripSuppressedRanges())
        var pending = decodePending(prefs.getTripScanPending())
        pending?.takeIf { inclusiveDayCount(Date(it.start), Date(it.end)) > AppConfig.TRIP_MAXIMUM_DURATION_DAYS }?.let { loaded ->
            val chunks = splitPending(loaded, AppConfig.TRIP_MAXIMUM_DURATION_DAYS)
            chunks.dropLast(1).forEach { persist(it, home, db, prefs) }
            pending = chunks.lastOrNull()
        }
        var cursor = start
        while (cursor.before(end)) {
            val nextDay = Calendar.getInstance().apply { time = cursor; add(Calendar.DAY_OF_YEAR, 1) }.time
            val cursorTime = startOfDay(cursor).time
            val isSuppressed = suppressedRanges.any { cursorTime in it.first..it.second }
            val alreadyCovered = onlyMissingDates && existingTrips.any {
                cursorTime in startOfDay(it.plannedStartDay).time..startOfDay(it.plannedEndDay).time
            }
            if (isSuppressed || alreadyCovered) {
                pending?.let { persist(it, home, db, prefs) }
                pending = null
                cursor = nextDay
                continue
            }
            val dayFootprints = footprints.filter { it.startTime.before(nextDay) && it.endTime.after(cursor) }
            val orderedCities = dayFootprints.mapNotNull { fp ->
                fp.cityName?.trim()?.takeIf { it.isNotEmpty() }?.let {
                    City(fp.countryCode.orEmpty(), fp.countryName.orEmpty(), it, firstCoordinate(fp.latitudeJson), firstCoordinate(fp.longitudeJson))
                }
            }
            val cities = orderedCities.distinctBy { cityKey(it.countryCode, it.cityName) }
            val homeDay = cities.any { cityMatches(it, home) }
            val away = cities.filterNot { cityMatches(it, home) }
            if (away.isNotEmpty()) {
                if (pending != null && inclusiveDayCount(Date(pending!!.start), cursor) > AppConfig.TRIP_MAXIMUM_DURATION_DAYS) {
                    persist(pending!!, home, db, prefs)
                    pending = null
                }
                val current = pending ?: Pending(cursor.time, cursor.time, linkedMapOf()).also { pending = it }
                current.end = cursor.time
                current.days[dayKey(cursor)] = away
            }
            val endedAtHome = orderedCities.lastOrNull()?.let { cityMatches(it, home) } ?: homeDay
            if (endedAtHome) {
                pending?.let { persist(it, home, db, prefs) }
                pending = null
            }
            calendar.time = cursor; calendar.add(Calendar.DAY_OF_YEAR, 1); cursor = calendar.time
        }
        prefs.setTripScanPending(encodePending(pending))
        prefs.setTripScanCursor(end.time)
        end.before(today)
    }

    private fun cityMatches(city: City, home: HomeCityEntity): Boolean {
        if (normalized(city.cityName) != normalized(home.cityName)) return false
        val cityCountry = normalized(city.countryCode)
        val homeCountry = normalized(home.countryCode)
        return cityCountry.isEmpty() || homeCountry.isEmpty() || cityCountry == homeCountry
    }

    private fun normalized(value: String) = value.trim().lowercase()

    private fun decodeSuppressedRanges(value: String?): List<Pair<Long, Long>> = runCatching {
        val array = JSONArray(value ?: "[]")
        (0 until array.length()).mapNotNull { index ->
            val item = array.optJSONObject(index) ?: return@mapNotNull null
            val start = item.optLong("start", Long.MIN_VALUE)
            val end = item.optLong("end", Long.MIN_VALUE)
            if (start == Long.MIN_VALUE || end == Long.MIN_VALUE) null else minOf(start, end) to maxOf(start, end)
        }
    }.getOrDefault(emptyList())

    private suspend fun persist(pending: Pending, home: HomeCityEntity, db: AppDatabase, prefs: AppPreferences) {
        val pendingStart = startOfDay(Date(pending.start)).time
        val pendingEnd = startOfDay(Date(pending.end)).time
        if (decodeSuppressedRanges(prefs.getTripSuppressedRanges()).any {
                it.first <= pendingEnd && it.second >= pendingStart
            }) return
        val dao = db.tripDao()
        val endExclusive = Calendar.getInstance().apply {
            time = startOfDay(Date(pending.end))
            add(Calendar.DAY_OF_YEAR, 1)
        }.time
        val footprints = db.footprintDao().getBetween(startOfDay(Date(pending.start)), endExclusive)
        val existing = dao.getTrips().firstOrNull {
            val mergedStart = minOf(it.plannedStartDay, Date(pending.start))
            val mergedEnd = maxOf(it.plannedEndDay, Date(pending.end))
            !it.plannedStartDay.after(Date(pending.end))
                && !it.plannedEndDay.before(Date(pending.start))
                && (it.originRaw != "automatic"
                    || inclusiveDayCount(mergedStart, mergedEnd) <= AppConfig.TRIP_MAXIMUM_DURATION_DAYS)
        }
        val trip = existing?.copy(
            plannedStartDay = if (existing.datesUserEdited) existing.plannedStartDay else minOf(existing.plannedStartDay, Date(pending.start)),
            plannedEndDay = if (existing.datesUserEdited) existing.plannedEndDay else maxOf(existing.plannedEndDay, Date(pending.end)),
            activityTypeValue = existing.activityTypeValue ?: dominantAwayActivityType(footprints, home),
            stateRaw = if (existing.state == TripState.DRAFT) TripState.HISTORICAL.raw else existing.stateRaw,
            updatedAt = Date()
        ) ?: TripEntity(
            title = automaticTitle(pending.days.values.flatten(), home),
            activityTypeValue = dominantAwayActivityType(footprints, home),
            kindRaw = TripKind.HISTORICAL.raw,
            stateRaw = TripState.HISTORICAL.raw,
            originRaw = "automatic",
            plannedStartDay = Date(pending.start),
            plannedEndDay = Date(pending.end),
            homeCityKeyAtCreation = cityKey(home.countryCode, home.cityName)
        )
        dao.upsertTrip(trip)
        val existingDays = dao.getAllDays().filter { it.tripID == trip.id }
        val daysByKey = existingDays.associateBy { dayKey(it.day) }.toMutableMap()
        val existingCities = dao.getAllCities()
        pending.days.forEach { (key, cities) ->
            val date = dayFormat().parse(key) ?: return@forEach
            val day = daysByKey[key] ?: TripDayEntity(tripID = trip.id, day = date)
            dao.upsertDay(day)
            daysByKey[key] = day
            val present = existingCities.filter { it.tripDayID == day.id }.map { cityKey(it.countryCode, it.cityName) }.toSet()
            cities.forEachIndexed { index, city ->
                if (cityKey(city.countryCode, city.cityName) !in present) {
                    dao.upsertCity(TripDayCityEntity(tripDayID = day.id, countryCode = city.countryCode, countryName = city.countryName, cityName = city.cityName, latitude = city.latitude, longitude = city.longitude, orderIndex = index, isUserEdited = false))
                }
            }
        }
    }

    private fun dominantAwayActivityType(footprints: List<FootprintEntity>, home: HomeCityEntity): String? {
        val counts = linkedMapOf<String, Int>()
        footprints.forEach { footprint ->
            val city = footprint.cityName?.trim().orEmpty()
            val isHome = city.isNotEmpty() && cityMatches(
                City(footprint.countryCode.orEmpty(), footprint.countryName.orEmpty(), city, null, null),
                home
            )
            val value = footprint.activityTypeValue?.trim().orEmpty()
            if (!isHome && value.isNotEmpty()) counts[value] = (counts[value] ?: 0) + 1
        }
        return counts.maxByOrNull { it.value }?.key
    }

    private fun inclusiveDayCount(start: Date, end: Date): Int {
        val calendar = Calendar.getInstance()
        var cursor = startOfDay(start)
        val last = startOfDay(end)
        var count = 1
        while (cursor.before(last)) {
            calendar.time = cursor
            calendar.add(Calendar.DAY_OF_YEAR, 1)
            cursor = calendar.time
            count += 1
        }
        return count
    }

    private fun splitPending(pending: Pending, maximumDays: Int): List<Pending> {
        var chunkStart = startOfDay(Date(pending.start))
        val finalDay = startOfDay(Date(pending.end))
        return buildList {
            while (!chunkStart.after(finalDay)) {
                val chunkEnd = Calendar.getInstance().apply {
                    time = chunkStart
                    add(Calendar.DAY_OF_YEAR, maximumDays - 1)
                }.time.coerceAtMost(finalDay)
                val chunkDays = LinkedHashMap(pending.days.filterKeys { key ->
                    val date = dayFormat().parse(key) ?: return@filterKeys false
                    !date.before(chunkStart) && !date.after(chunkEnd)
                })
                if (chunkDays.isNotEmpty()) add(Pending(chunkStart.time, chunkEnd.time, chunkDays))
                chunkStart = Calendar.getInstance().apply {
                    time = chunkEnd
                    add(Calendar.DAY_OF_YEAR, 1)
                }.time
            }
        }
    }

    private fun automaticTitle(cities: List<City>, home: HomeCityEntity): String {
        val foreignCountries = cities
            .filter { isKnownForeignCountry(it, home) }
            .distinctBy { it.countryCode.trim().uppercase().ifEmpty { normalized(it.countryName) } }
            .map { it.countryName.trim().ifEmpty { it.countryCode.trim().uppercase() } }
            .filter { it.isNotEmpty() }
        if (foreignCountries.isNotEmpty()) return foreignCountries.take(3).joinToString("、")
        return cities.map { it.cityName }.distinct().take(3).joinToString("、")
    }

    private fun isKnownForeignCountry(city: City, home: HomeCityEntity): Boolean {
        val cityCode = normalized(city.countryCode)
        val homeCode = normalized(home.countryCode)
        if (cityCode.isNotEmpty() && homeCode.isNotEmpty()) return cityCode != homeCode
        val cityCountry = normalized(city.countryName)
        val homeCountry = normalized(home.countryName)
        return cityCountry.isNotEmpty() && homeCountry.isNotEmpty() && cityCountry != homeCountry
    }

    private data class City(val countryCode: String, val countryName: String, val cityName: String, val latitude: Double?, val longitude: Double?)
    private data class Pending(var start: Long, var end: Long, val days: LinkedHashMap<String, List<City>>)
    private fun encodePending(value: Pending?): String? = value?.let { p ->
        JSONObject().put("start", p.start).put("end", p.end).put("days", JSONObject().also { days ->
            p.days.forEach { (key, cities) -> days.put(key, JSONArray().also { array -> cities.forEach { city -> array.put(JSONObject().put("countryCode", city.countryCode).put("countryName", city.countryName).put("cityName", city.cityName).put("latitude", city.latitude).put("longitude", city.longitude)) } }) }
        }).toString()
    }

    private fun decodePending(raw: String?): Pending? = runCatching {
        raw ?: return null
        val objectValue = JSONObject(raw); val daysObject = objectValue.getJSONObject("days"); val days = linkedMapOf<String, List<City>>()
        daysObject.keys().forEach { key ->
            val array = daysObject.getJSONArray(key)
            days[key] = (0 until array.length()).map { index ->
                val city = array.getJSONObject(index)
                City(city.optString("countryCode"), city.optString("countryName"), city.getString("cityName"), city.optDouble("latitude").takeUnless { it.isNaN() }, city.optDouble("longitude").takeUnless { it.isNaN() })
            }
        }
        Pending(objectValue.getLong("start"), objectValue.getLong("end"), days)
    }.getOrNull()

    private fun startOfDay(date: Date) = Calendar.getInstance().apply { time = date; set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0) }.time
    private fun dayKey(date: Date) = dayFormat().format(date)
    private fun dayFormat() = SimpleDateFormat("yyyy-MM-dd", Locale.US)
    private fun cityKey(country: String, city: String) = "${country.trim().lowercase()}|${city.trim().lowercase()}"
    private fun firstCoordinate(json: String): Double? = runCatching { JSONArray(json).optDouble(0).takeUnless { it.isNaN() } }.getOrNull()
    private fun Date.coerceAtMost(other: Date) = if (after(other)) other else this
}
