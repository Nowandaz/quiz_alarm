package com.gdelataillade.alarm.alarm
class AlarmService { companion object { var ringing = listOf<Int>()
  @JvmStatic val ringingAlarmIds: List<Int> get() = ringing; @JvmStatic val queuedAlarmIds: List<Int> get() = listOf() } }
