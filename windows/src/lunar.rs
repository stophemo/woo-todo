//! 农历与传统节日标注，对齐 macOS `TraditionalCalendarInfo`。
//!
//! 农历月日使用 ICU4X 中文日历（与 macOS Foundation 的 `Calendar(identifier: .chinese)`
//! 同源的农历规则）；二十四节气、农历节日与公历节日使用与 macOS 完全相同的
//! 表与公式，保证两端悬浮任务板显示一致。

use chrono::{Datelike, NaiveDate, TimeZone, Utc};
use icu_calendar::Date;
use icu_calendar::cal::ChineseTraditional;

const LUNAR_MONTHS: [&str; 12] = [
    "正", "二", "三", "四", "五", "六", "七", "八", "九", "十", "冬", "腊",
];
const LUNAR_DAYS: [&str; 30] = [
    "初一", "初二", "初三", "初四", "初五", "初六", "初七", "初八", "初九", "初十", "十一", "十二",
    "十三", "十四", "十五", "十六", "十七", "十八", "十九", "二十", "廿一", "廿二", "廿三", "廿四",
    "廿五", "廿六", "廿七", "廿八", "廿九", "三十",
];

/// 与 macOS `TraditionalCalendarInfo` 的节气表完全一致：
/// `(名称, 距基准日 1900-01-06 02:05 UTC 的分钟数)`。
const SOLAR_TERMS: [(&str, i64); 24] = [
    ("小寒", 0),
    ("大寒", 21_208),
    ("立春", 42_467),
    ("雨水", 63_836),
    ("惊蛰", 85_337),
    ("春分", 107_014),
    ("清明", 128_867),
    ("谷雨", 150_921),
    ("立夏", 173_149),
    ("小满", 195_551),
    ("芒种", 218_072),
    ("夏至", 240_693),
    ("小暑", 263_343),
    ("大暑", 285_989),
    ("立秋", 308_563),
    ("处暑", 331_033),
    ("白露", 353_350),
    ("秋分", 375_494),
    ("寒露", 397_447),
    ("霜降", 419_210),
    ("立冬", 440_795),
    ("小雪", 462_224),
    ("大雪", 483_532),
    ("冬至", 504_758),
];
const TROPICAL_YEAR_MILLISECONDS: f64 = 31_556_925_974.7;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TraditionalCalendarInfo {
    pub lunar_date: String,
    pub annotation: Option<String>,
}

impl TraditionalCalendarInfo {
    /// 按 Asia/Shanghai 日期渲染农历与节日标注（应用其余部分统一使用上海日期）。
    pub fn render(date: NaiveDate) -> Self {
        let (lunar_month, lunar_day, is_leap_month) = lunar_components(date);
        let (next_month, next_day, _) = lunar_components(
            date.succ_opt()
                .unwrap_or_else(|| date.checked_add_days(chrono::Days::new(1)).unwrap_or(date)),
        );

        let lunar_text = lunar_date_text(lunar_month, lunar_day, is_leap_month);
        let mut notes = Vec::new();
        if let Some(term) = solar_term(date.year(), date.month(), date.day()) {
            notes.push(term);
        }
        if let Some(festival) =
            lunar_festival(lunar_month, lunar_day, is_leap_month, next_month, next_day)
        {
            notes.push(festival);
        }
        if let Some(festival) = solar_festival(date.month(), date.day()) {
            notes.push(festival);
        }
        notes.dedup();

        Self {
            lunar_date: lunar_text,
            annotation: if notes.is_empty() {
                None
            } else {
                Some(notes.join(" · "))
            },
        }
    }
}

/// 返回（农历月，农历日，是否闰月）。ICU 中文日历覆盖 1900–2100 之后的范围；
/// 超出数据范围时回退为公历日期本身，避免显示错误。
fn lunar_components(date: NaiveDate) -> (u32, u32, bool) {
    let Ok(iso) = Date::try_new_iso(date.year(), date.month() as u8, date.day() as u8) else {
        return (date.month(), date.day(), false);
    };
    let chinese = iso.to_calendar(ChineseTraditional::new());
    let month = chinese.month();
    (
        month.number() as u32,
        chinese.day_of_month().0 as u32,
        month.to_input().is_leap(),
    )
}

fn lunar_date_text(month: u32, day: u32, is_leap_month: bool) -> String {
    let month_name = LUNAR_MONTHS
        .get(month.saturating_sub(1) as usize)
        .copied()
        .unwrap_or("");
    let day_name = LUNAR_DAYS
        .get(day.saturating_sub(1) as usize)
        .copied()
        .unwrap_or("");
    format!(
        "农历{}{}月{}",
        if is_leap_month { "闰" } else { "" },
        month_name,
        day_name
    )
}

fn lunar_festival(
    month: u32,
    day: u32,
    is_leap_month: bool,
    next_month: u32,
    next_day: u32,
) -> Option<&'static str> {
    if is_leap_month {
        return None;
    }
    if next_month == 1 && next_day == 1 {
        return Some("除夕");
    }
    lunar_festival_name(month, day)
}

fn lunar_festival_name(month: u32, day: u32) -> Option<&'static str> {
    match (month, day) {
        (1, 1) => Some("春节"),
        (1, 15) => Some("元宵节"),
        (2, 2) => Some("龙抬头"),
        (5, 5) => Some("端午节"),
        (7, 7) => Some("七夕"),
        (7, 15) => Some("中元节"),
        (8, 15) => Some("中秋节"),
        (9, 9) => Some("重阳节"),
        (12, 8) => Some("腊八节"),
        _ => None,
    }
}

fn solar_festival(month: u32, day: u32) -> Option<&'static str> {
    match (month, day) {
        (1, 1) => Some("元旦"),
        (3, 8) => Some("妇女节"),
        (5, 1) => Some("劳动节"),
        (5, 4) => Some("青年节"),
        (6, 1) => Some("儿童节"),
        (10, 1) => Some("国庆节"),
        _ => None,
    }
}

/// 与 macOS 相同的节气计算：以 1900-01-06 02:05 UTC 为基准，
/// 用回归年线性外推，按 UTC 时刻落在的（月，日）匹配节气。
fn solar_term(year: i32, month: u32, day: u32) -> Option<&'static str> {
    if !(1900..=2100).contains(&year) {
        return None;
    }
    let base = Utc
        .with_ymd_and_hms(1900, 1, 6, 2, 5, 0)
        .single()?
        .timestamp();
    SOLAR_TERMS.iter().find_map(|(name, minutes)| {
        let seconds = tropical_year_offset_seconds(year, *minutes);
        let term_date = Utc.timestamp_opt(base + seconds, 0).single()?.date_naive();
        (term_date.month() == month && term_date.day() == day).then_some(*name)
    })
}

/// `回归年 × 年差 + 节气分钟数`，转换为秒；运算顺序与 Swift 端保持一致。
fn tropical_year_offset_seconds(year: i32, minutes: i64) -> i64 {
    let milliseconds =
        TROPICAL_YEAR_MILLISECONDS * (year - 1900) as f64 + minutes as f64 * 60_000.0;
    (milliseconds / 1_000.0).floor() as i64
}

#[cfg(test)]
mod tests {
    use super::*;

    fn date(year: i32, month: u32, day: u32) -> NaiveDate {
        NaiveDate::from_ymd_opt(year, month, day).unwrap()
    }

    #[test]
    fn known_lunar_new_year_dates_match_authoritative_values() {
        for (day, expected) in [
            (date(2023, 1, 22), "农历正月初一"),
            (date(2024, 2, 10), "农历正月初一"),
            (date(2025, 1, 29), "农历正月初一"),
            (date(2026, 2, 17), "农历正月初一"),
            (date(2023, 6, 22), "农历五月初五"),
            (date(2024, 9, 17), "农历八月十五"),
            (date(2025, 10, 6), "农历八月十五"),
            (date(2026, 8, 17), "农历七月初五"),
        ] {
            assert_eq!(
                TraditionalCalendarInfo::render(day).lunar_date,
                expected,
                "{day}"
            );
        }
    }

    #[test]
    fn leap_months_are_rendered_with_闰_prefix() {
        assert_eq!(
            TraditionalCalendarInfo::render(date(2023, 3, 22)).lunar_date,
            "农历闰二月初一"
        );
        assert_eq!(
            TraditionalCalendarInfo::render(date(2025, 7, 25)).lunar_date,
            "农历闰六月初一"
        );
    }

    #[test]
    fn festivals_and_eve_are_annotated() {
        let spring_festival = TraditionalCalendarInfo::render(date(2025, 1, 29));
        assert_eq!(spring_festival.annotation.as_deref(), Some("春节"),);
        let eve = TraditionalCalendarInfo::render(date(2025, 1, 28));
        assert_eq!(eve.annotation.as_deref(), Some("除夕"));
        let mid_autumn = TraditionalCalendarInfo::render(date(2025, 10, 6));
        assert_eq!(mid_autumn.annotation.as_deref(), Some("中秋节"));
        let national_day = TraditionalCalendarInfo::render(date(2026, 10, 1));
        assert_eq!(national_day.annotation.as_deref(), Some("国庆节"));
    }

    #[test]
    fn solar_terms_match_macos_formula() {
        assert_eq!(
            TraditionalCalendarInfo::render(date(2026, 8, 7))
                .annotation
                .as_deref(),
            Some("立秋")
        );
        assert_eq!(
            TraditionalCalendarInfo::render(date(2026, 8, 23))
                .annotation
                .as_deref(),
            Some("处暑")
        );
        assert_eq!(
            TraditionalCalendarInfo::render(date(2025, 12, 21))
                .annotation
                .as_deref(),
            Some("冬至")
        );
        // 2026-03-20 恰逢春分与农历二月初二（龙抬头）。
        assert_eq!(
            TraditionalCalendarInfo::render(date(2026, 3, 20))
                .annotation
                .as_deref(),
            Some("春分 · 龙抬头")
        );
    }

    #[test]
    fn festival_and_solar_term_can_stack_on_the_same_day() {
        // 2020-10-01：国庆节与中秋节（八月十五）恰逢同日。
        let info = TraditionalCalendarInfo::render(date(2020, 10, 1));
        let annotation = info.annotation.as_deref().unwrap_or("");
        assert!(annotation.contains("中秋节"), "{annotation}");
        assert!(annotation.contains("国庆节"), "{annotation}");
    }

    #[test]
    fn ordinary_days_have_no_annotation() {
        assert_eq!(
            TraditionalCalendarInfo::render(date(2026, 8, 12)).annotation,
            None
        );
    }
}
