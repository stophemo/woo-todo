use chrono::{Datelike, Duration, Local, Months, NaiveDate};
use serde::{Deserialize, Serialize};

pub const DEFAULT_HEADER_TEMPLATE: &str = "今日任务";
pub const MAX_HEADER_CHARACTERS: usize = 80;
pub const MAX_SUBTITLE_CHARACTERS: usize = 160;

const ZERO_MONTHS_DAYS: &str = "0个月零0天";
const WEEKDAYS: [&str; 7] = [
    "星期一",
    "星期二",
    "星期三",
    "星期四",
    "星期五",
    "星期六",
    "星期日",
];
const WEEKDAYS_SHORT: [&str; 7] = ["一", "二", "三", "四", "五", "六", "日"];
const WEEKDAYS_EN: [&str; 7] = [
    "Monday",
    "Tuesday",
    "Wednesday",
    "Thursday",
    "Friday",
    "Saturday",
    "Sunday",
];
const WEEKDAYS_EN_SHORT: [&str; 7] = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[allow(clippy::enum_variant_names)]
pub enum CounterVariable {
    ElapsedDays,
    DeadlineDays,
    ElapsedMonthsDays,
    DeadlineMonthsDays,
}

impl CounterVariable {
    fn token_name(self) -> &'static str {
        match self {
            Self::ElapsedDays => "elapsedDays",
            Self::DeadlineDays => "deadlineDays",
            Self::ElapsedMonthsDays => "elapsedMonthsDays",
            Self::DeadlineMonthsDays => "deadlineMonthsDays",
        }
    }

    fn from_token_name(value: &str) -> Option<Self> {
        match value {
            "elapsedDays" => Some(Self::ElapsedDays),
            "deadlineDays" => Some(Self::DeadlineDays),
            "elapsedMonthsDays" => Some(Self::ElapsedMonthsDays),
            "deadlineMonthsDays" => Some(Self::DeadlineMonthsDays),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "PascalCase", default)]
pub struct DisplayConfiguration {
    pub header_template: String,
    pub subtitle_template: String,
    /// 仅用于兼容旧版无参数耗时变量。
    pub start_date: NaiveDate,
    /// 仅用于兼容旧版无参数截止变量。
    pub deadline_date: NaiveDate,
}

impl Default for DisplayConfiguration {
    fn default() -> Self {
        let today = Local::now().date_naive();
        Self {
            header_template: DEFAULT_HEADER_TEMPLATE.to_string(),
            subtitle_template: String::new(),
            start_date: today,
            deadline_date: today,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DisplayConfigurationError {
    HeaderTooLong,
    SubtitleTooLong,
    HeaderMustBeSingleLine,
    SubtitleMustBeSingleLine,
}

impl DisplayConfiguration {
    pub fn validate(&self) -> Result<(), DisplayConfigurationError> {
        if contains_line_break(&self.header_template) {
            return Err(DisplayConfigurationError::HeaderMustBeSingleLine);
        }
        if contains_line_break(&self.subtitle_template) {
            return Err(DisplayConfigurationError::SubtitleMustBeSingleLine);
        }
        if self.header_template.chars().count() > MAX_HEADER_CHARACTERS {
            return Err(DisplayConfigurationError::HeaderTooLong);
        }
        if self.subtitle_template.chars().count() > MAX_SUBTITLE_CHARACTERS {
            return Err(DisplayConfigurationError::SubtitleTooLong);
        }
        Ok(())
    }

    pub fn render(&self, date: NaiveDate) -> (Option<String>, Option<String>) {
        (self.render_header(date), self.render_subtitle(date))
    }

    pub fn render_header(&self, date: NaiveDate) -> Option<String> {
        self.render_template(&self.header_template, date)
    }

    pub fn render_subtitle(&self, date: NaiveDate) -> Option<String> {
        self.render_template(&self.subtitle_template, date)
    }

    pub fn counter_token(variable: CounterVariable, date: NaiveDate) -> String {
        counter_token(variable, date)
    }

    fn render_template(&self, template: &str, current: NaiveDate) -> Option<String> {
        let normalized = template.trim();
        if normalized.is_empty() {
            return None;
        }

        let elapsed = current.signed_duration_since(self.start_date).num_days();
        let elapsed_days = (elapsed + 1).max(0);
        let deadline_days = self.deadline_date.signed_duration_since(current).num_days();
        let elapsed_months_days = if current < self.start_date {
            ZERO_MONTHS_DAYS.to_string()
        } else {
            current
                .checked_add_signed(Duration::days(1))
                .map(|end| months_days(self.start_date, end))
                .unwrap_or_else(|| ZERO_MONTHS_DAYS.to_string())
        };
        let deadline_months_days = months_days(current, self.deadline_date);
        let weekday_index = current.weekday().num_days_from_monday() as usize;
        let iso_date = format_iso_date(current);
        let date_long = format!(
            "{}年{}月{}日",
            current.year(),
            current.month(),
            current.day()
        );

        let parameterized = render_parameterized_counters(normalized, current);
        let variables = [
            ("{weekday}", WEEKDAYS[weekday_index].to_string()),
            ("{weekdayShort}", WEEKDAYS_SHORT[weekday_index].to_string()),
            ("{weekdayEn}", WEEKDAYS_EN[weekday_index].to_string()),
            (
                "{weekdayEnShort}",
                WEEKDAYS_EN_SHORT[weekday_index].to_string(),
            ),
            ("{date}", iso_date),
            ("{dateLong}", date_long),
            ("{year}", current.year().to_string()),
            ("{month}", current.month().to_string()),
            ("{monthPadded}", format!("{:02}", current.month())),
            ("{day}", current.day().to_string()),
            ("{dayPadded}", format!("{:02}", current.day())),
            ("{startDate}", format_iso_date(self.start_date)),
            ("{deadlineDate}", format_iso_date(self.deadline_date)),
            ("{elapsedDays}", elapsed_days.to_string()),
            ("{deadlineDays}", deadline_days.to_string()),
            ("{elapsedMonthsDays}", elapsed_months_days),
            ("{deadlineMonthsDays}", deadline_months_days),
        ];

        Some(
            variables
                .into_iter()
                .fold(parameterized, |rendered, (token, value)| {
                    rendered.replace(token, &value)
                }),
        )
    }
}

pub fn counter_token(variable: CounterVariable, date: NaiveDate) -> String {
    format!("{{{}:{}}}", variable.token_name(), format_iso_date(date))
}

fn render_parameterized_counters(source: &str, current: NaiveDate) -> String {
    let mut rendered = String::with_capacity(source.len());
    let mut cursor = 0;

    while let Some(relative_start) = source[cursor..].find('{') {
        let start = cursor + relative_start;
        rendered.push_str(&source[cursor..start]);
        let Some(relative_end) = source[start + 1..].find('}') else {
            rendered.push_str(&source[start..]);
            return rendered;
        };
        let end = start + 1 + relative_end;
        let content = &source[start + 1..end];
        if let Some((variable, reference_date)) = parse_parameterized_counter(content) {
            rendered.push_str(&counter_value(variable, reference_date, current));
            cursor = end + 1;
        } else {
            rendered.push('{');
            cursor = start + 1;
        }
    }

    rendered.push_str(&source[cursor..]);
    rendered
}

fn parse_parameterized_counter(content: &str) -> Option<(CounterVariable, NaiveDate)> {
    let (variable, date) = content.split_once(':')?;
    let variable = CounterVariable::from_token_name(variable)?;
    if !has_iso_date_shape(date) {
        return None;
    }
    let date = NaiveDate::parse_from_str(date, "%Y-%m-%d").ok()?;
    Some((variable, date))
}

fn counter_value(
    variable: CounterVariable,
    reference_date: NaiveDate,
    current: NaiveDate,
) -> String {
    match variable {
        CounterVariable::ElapsedDays => (current.signed_duration_since(reference_date).num_days()
            + 1)
        .max(0)
        .to_string(),
        CounterVariable::DeadlineDays => reference_date
            .signed_duration_since(current)
            .num_days()
            .to_string(),
        CounterVariable::ElapsedMonthsDays => {
            if current < reference_date {
                ZERO_MONTHS_DAYS.to_string()
            } else {
                current
                    .checked_add_signed(Duration::days(1))
                    .map(|end| months_days(reference_date, end))
                    .unwrap_or_else(|| ZERO_MONTHS_DAYS.to_string())
            }
        }
        CounterVariable::DeadlineMonthsDays => months_days(current, reference_date),
    }
}

fn months_days(source: NaiveDate, destination: NaiveDate) -> String {
    if source == destination {
        return ZERO_MONTHS_DAYS.to_string();
    }

    let negative = destination < source;
    let (earlier, later) = if negative {
        (destination, source)
    } else {
        (source, destination)
    };
    let mut months =
        (later.year() - earlier.year()) * 12 + later.month() as i32 - earlier.month() as i32;
    let mut month_boundary = earlier
        .checked_add_months(Months::new(months as u32))
        .unwrap_or(earlier);
    if month_boundary > later {
        months -= 1;
        month_boundary = earlier
            .checked_add_months(Months::new(months as u32))
            .unwrap_or(earlier);
    }
    let days = later.signed_duration_since(month_boundary).num_days();
    let sign = if negative { "-" } else { "" };
    format!("{sign}{months}个月零{days}天")
}

fn has_iso_date_shape(value: &str) -> bool {
    let bytes = value.as_bytes();
    bytes.len() == 10
        && bytes[4] == b'-'
        && bytes[7] == b'-'
        && bytes
            .iter()
            .enumerate()
            .all(|(index, byte)| index == 4 || index == 7 || byte.is_ascii_digit())
}

fn format_iso_date(value: NaiveDate) -> String {
    format!(
        "{:04}-{:02}-{:02}",
        value.year(),
        value.month(),
        value.day()
    )
}

fn contains_line_break(value: &str) -> bool {
    value.chars().any(|character| {
        matches!(
            character,
            '\n' | '\r' | '\u{000B}' | '\u{000C}' | '\u{0085}' | '\u{2028}' | '\u{2029}'
        )
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn date(year: i32, month: u32, day: u32) -> NaiveDate {
        NaiveDate::from_ymd_opt(year, month, day).unwrap()
    }

    #[test]
    fn parameterized_counters_use_independent_dates() {
        let configuration = DisplayConfiguration {
            header_template: "{elapsedDays:2026-12-31}|{elapsedDays:2027-01-02}|{deadlineDays:2027-01-01}|{deadlineDays:2027-02-02}".to_string(),
            subtitle_template: "{elapsedMonthsDays:2026-11-02}|{elapsedMonthsDays:2026-12-31}|{deadlineMonthsDays:2026-12-02}|{deadlineMonthsDays:2027-02-02}".to_string(),
            start_date: date(2020, 1, 1),
            deadline_date: date(2030, 1, 1),
        };

        assert_eq!(
            configuration.render_header(date(2027, 1, 2)).as_deref(),
            Some("3|1|-1|31")
        );
        assert_eq!(
            configuration.render_subtitle(date(2027, 1, 2)).as_deref(),
            Some("2个月零1天|0个月零3天|-1个月零0天|1个月零0天")
        );
    }

    #[test]
    fn counter_token_always_contains_its_own_date() {
        assert_eq!(
            counter_token(CounterVariable::ElapsedDays, date(2026, 12, 31)),
            "{elapsedDays:2026-12-31}"
        );
        assert_eq!(
            DisplayConfiguration::counter_token(
                CounterVariable::DeadlineMonthsDays,
                date(2027, 2, 2)
            ),
            "{deadlineMonthsDays:2027-02-02}"
        );
    }

    #[test]
    fn invalid_and_unknown_tokens_remain_literal() {
        let configuration = DisplayConfiguration {
            header_template: "{elapsedDays:2026-02-30}|{custom}|{elapsedDays:2026-2-03}"
                .to_string(),
            ..DisplayConfiguration::default()
        };

        assert_eq!(
            configuration.render_header(date(2026, 2, 3)).as_deref(),
            Some("{elapsedDays:2026-02-30}|{custom}|{elapsedDays:2026-2-03}")
        );
    }

    #[test]
    fn month_end_leap_day_and_same_day_use_natural_months() {
        assert_eq!(
            months_days(date(2026, 1, 31), date(2026, 2, 28)),
            "1个月零0天"
        );
        assert_eq!(
            months_days(date(2024, 2, 29), date(2025, 2, 28)),
            "12个月零0天"
        );
        assert_eq!(
            months_days(date(2026, 2, 28), date(2026, 1, 31)),
            "-1个月零0天"
        );

        let configuration = DisplayConfiguration {
            header_template: "{elapsedMonthsDays}".to_string(),
            subtitle_template: "{deadlineMonthsDays}".to_string(),
            start_date: date(2026, 7, 24),
            deadline_date: date(2026, 7, 24),
        };
        assert_eq!(
            configuration.render_header(date(2026, 7, 24)).as_deref(),
            Some("0个月零1天")
        );
        assert_eq!(
            configuration.render_subtitle(date(2026, 7, 24)).as_deref(),
            Some("0个月零0天")
        );
    }

    #[test]
    fn future_start_is_zero_and_past_deadline_is_negative() {
        let configuration = DisplayConfiguration {
            header_template: "{elapsedDays}|{elapsedMonthsDays}".to_string(),
            subtitle_template: "{deadlineDays}|{deadlineMonthsDays}".to_string(),
            start_date: date(2026, 7, 27),
            deadline_date: date(2026, 6, 21),
        };

        assert_eq!(
            configuration.render_header(date(2026, 7, 24)).as_deref(),
            Some("0|0个月零0天")
        );
        assert_eq!(
            configuration.render_subtitle(date(2026, 7, 24)).as_deref(),
            Some("-33|-1个月零3天")
        );
    }

    #[test]
    fn renders_all_weekday_and_date_tokens() {
        let configuration = DisplayConfiguration {
            header_template: "{weekday}|{weekdayShort}|{weekdayEn}|{weekdayEnShort}".to_string(),
            subtitle_template: "{date}|{dateLong}|{year}/{month}/{day}|{monthPadded}/{dayPadded}|{startDate}->{deadlineDate}".to_string(),
            start_date: date(2026, 12, 31),
            deadline_date: date(2027, 1, 9),
        };
        let expected = [
            "星期一|一|Monday|Mon",
            "星期二|二|Tuesday|Tue",
            "星期三|三|Wednesday|Wed",
            "星期四|四|Thursday|Thu",
            "星期五|五|Friday|Fri",
            "星期六|六|Saturday|Sat",
            "星期日|日|Sunday|Sun",
        ];
        let monday = date(2026, 7, 20);

        for (offset, expected) in expected.into_iter().enumerate() {
            let current = monday + Duration::days(offset as i64);
            assert_eq!(
                configuration.render_header(current).as_deref(),
                Some(expected)
            );
        }
        assert_eq!(
            configuration.render_subtitle(date(2027, 1, 2)).as_deref(),
            Some("2027-01-02|2027年1月2日|2027/1/2|01/02|2026-12-31->2027-01-09")
        );
    }

    #[test]
    fn blank_templates_render_as_none() {
        let configuration = DisplayConfiguration {
            header_template: "  \t".to_string(),
            subtitle_template: String::new(),
            ..DisplayConfiguration::default()
        };

        assert_eq!(configuration.render(date(2026, 7, 24)), (None, None));
    }

    #[test]
    fn validation_uses_unicode_character_limits_and_rejects_all_line_breaks() {
        let valid = DisplayConfiguration {
            header_template: "标".repeat(MAX_HEADER_CHARACTERS),
            subtitle_template: "题".repeat(MAX_SUBTITLE_CHARACTERS),
            ..DisplayConfiguration::default()
        };
        assert_eq!(valid.validate(), Ok(()));

        let mut invalid = valid.clone();
        invalid.header_template.push('标');
        assert_eq!(
            invalid.validate(),
            Err(DisplayConfigurationError::HeaderTooLong)
        );

        let mut invalid = valid.clone();
        invalid.subtitle_template.push('题');
        assert_eq!(
            invalid.validate(),
            Err(DisplayConfigurationError::SubtitleTooLong)
        );

        let mut invalid = valid.clone();
        invalid.header_template = "第一行\u{2028}第二行".to_string();
        assert_eq!(
            invalid.validate(),
            Err(DisplayConfigurationError::HeaderMustBeSingleLine)
        );

        let mut invalid = valid;
        invalid.subtitle_template = "第一行\n第二行".to_string();
        assert_eq!(
            invalid.validate(),
            Err(DisplayConfigurationError::SubtitleMustBeSingleLine)
        );
    }
}
