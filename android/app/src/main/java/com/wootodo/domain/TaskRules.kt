package com.wootodo.domain

import java.time.LocalDate
import java.time.ZoneId

object TaskDateRules {
    val zoneId: ZoneId = ZoneId.of("Asia/Shanghai")

    fun today(): LocalDate = LocalDate.now(zoneId)
}
