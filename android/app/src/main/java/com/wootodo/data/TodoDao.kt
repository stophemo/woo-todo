package com.wootodo.data

import androidx.room.*
import kotlinx.coroutines.flow.Flow

@Dao
interface TodoDao {
    @Query("SELECT * FROM todos WHERE isDeleted = 0 ORDER BY updatedAt DESC")
    fun getAllTodos(): Flow<List<Todo>>

    @Query("SELECT * FROM todos WHERE id = :id")
    suspend fun getById(id: String): Todo?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(todo: Todo)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertAll(todos: List<Todo>)

    @Query("UPDATE todos SET isDeleted = 1, updatedAt = :updatedAt WHERE id = :id")
    suspend fun softDelete(id: String, updatedAt: Long = System.currentTimeMillis())

    @Query("SELECT * FROM todos WHERE updatedAt > :since ORDER BY updatedAt ASC")
    suspend fun getChangesSince(since: Long): List<Todo>

    @Query("SELECT * FROM todos WHERE syncedAt = 0 AND isDeleted = 0")
    suspend fun getUnsynced(): List<Todo>

    @Query("UPDATE todos SET syncedAt = :syncedAt WHERE id IN (:ids)")
    suspend fun markSynced(ids: List<String>, syncedAt: Long = System.currentTimeMillis())
}
