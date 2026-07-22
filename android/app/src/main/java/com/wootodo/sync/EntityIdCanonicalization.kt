package com.wootodo.sync

import java.util.Locale

internal fun canonicalEntityId(value: String): String = value.lowercase(Locale.ROOT)

internal fun TaskInstancePayload.withCanonicalEntityId(): TaskInstancePayload {
    val canonicalId = canonicalEntityId(id)
    return if (canonicalId == id) this else copy(id = canonicalId)
}

internal fun TombstonePayload.withCanonicalEntityId(): TombstonePayload {
    val canonicalId = canonicalEntityId(id)
    return if (canonicalId == id) this else copy(id = canonicalId)
}
