package com.wootodo.sync

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class WebDavPropfindParserInstrumentedTest {
    @Test
    fun `解析默认命名空间和前缀href并解码路径`() {
        val xml = """
            <?xml version="1.0" encoding="utf-8"?>
            <d:multistatus xmlns:d="DAV:">
              <d:response>
                <d:href>https://dav.example.com/remote.php/dav/files/person/woo-todo/v1/personal-vault/ops/ab/op%20one.json?ignored=1</d:href>
              </d:response>
              <d:response>
                <d:href>/remote.php/dav/files/person/woo-todo/v1/personal-vault/ops/cd/%E4%BB%BB%E5%8A%A1.json/</d:href>
              </d:response>
              <d:response>
                <d:href>v1/personal-vault/ops/ef/relative.json</d:href>
              </d:response>
              <d:response>
                <d:href>/remote.php/dav/files/person/other/path</d:href>
              </d:response>
            </d:multistatus>
        """.trimIndent()

        assertEquals(
            listOf(
                listOf("v1", "personal-vault", "ops", "ab", "op one.json"),
                listOf("v1", "personal-vault", "ops", "cd", "任务.json"),
                listOf("v1", "personal-vault", "ops", "ef", "relative.json"),
            ),
            WebDavPropfindParser.parse(
                xml,
                listOf("remote.php", "dav", "files", "person", "woo-todo"),
            ),
        )
    }

    @Test
    fun `解析DAV默认命名空间href`() {
        val xml = """
            <multistatus xmlns="DAV:">
              <response><href>/storage/v1-prefix/v1/vault-one/ops/ef/op.json</href></response>
            </multistatus>
        """.trimIndent()

        assertEquals(
            listOf(listOf("v1", "vault-one", "ops", "ef", "op.json")),
            WebDavPropfindParser.parse(xml, listOf("storage", "v1-prefix")),
        )
    }

    @Test
    fun `拒绝格式错误的href而不是静默漏掉远端操作`() {
        listOf(
            "/storage/v1/personal-vault/ops/ab/operation%ZZ.json",
            "/storage/v1/personal-vault/ops/%2e%2e/operation.json",
            "/storage/v1/personal-vault/ops/ab/operation%2fescape.json",
            "/storage/v1/personal-vault/ops/ab/operation%5cescape.json",
        ).forEach { href ->
            val xml = """
                <d:multistatus xmlns:d="DAV:">
                  <d:response><d:href>$href</d:href></d:response>
                </d:multistatus>
            """.trimIndent()

            assertThrows(WebDavException.MalformedObject::class.java) {
                WebDavPropfindParser.parse(xml, listOf("storage"))
            }
        }
    }
}
