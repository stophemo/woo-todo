package com.wootodo.di

import android.content.Context
import androidx.room.Room
import com.wootodo.data.TodoDao
import com.wootodo.data.TodoDatabase
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
object DatabaseModule {

    @Provides
    @Singleton
    fun provideDatabase(@ApplicationContext context: Context): TodoDatabase {
        return Room.databaseBuilder(
            context,
            TodoDatabase::class.java,
            "woo-todo.db"
        ).build()
    }

    @Provides
    fun provideTodoDao(db: TodoDatabase): TodoDao = db.todoDao()
}
