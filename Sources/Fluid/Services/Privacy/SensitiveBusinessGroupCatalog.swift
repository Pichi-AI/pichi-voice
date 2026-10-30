import Foundation

/// Opt-in vocabulary suggestions. These values are data, never evidence of misconduct.
/// `terms` may become user-reviewed word/phrase rules. `contextualExamples` are explanatory
/// examples only: consumers must not silently add them to the literal dictionary.
nonisolated struct SensitiveBusinessGroup: Identifiable, Equatable, Sendable {
    let id: String
    let titleKey: String
    let descriptionKey: String
    let terms: [String]
    let contextualExamples: [String]
}

/// A versioned catalog keeps suggested vocabulary separate from private user entries.
/// Selection and edits belong to the existing settings snapshot, not this catalog.
/// Russian vocabulary remains data and is not translated with interface labels.
nonisolated enum SensitiveBusinessGroupCatalog {
    static let version = "sensitive-business-groups-ru-v1"
    static let maximumCatalogTerms = 128
    static let defaultSelectedGroupIDs: Set<String> = []

    static let groups: [SensitiveBusinessGroup] = [
        .init(
            id: "illicit-remuneration",
            titleKey: "Bribes and illicit remuneration",
            descriptionKey: "Hide the listed expressions, including quotations and denials. Ambiguous words such as rollback or gratitude need context. A match does not establish misconduct.",
            terms: [
                "взятка", "взяточничество", "мзда", "мздоимство", "коммерческий подкуп",
                "дать на лапу", "незаконное вознаграждение", "подкуп должностного лица",
                "коррупционный платёж", "коррупционная выплата", "откат за контракт", "illegal kickback"
            ],
            contextualExamples: [
                "Личный процент человеку, который принимает решение по контракту.",
                "Благодарность за подпись без отражения в договоре.",
                "Занос, решение вопроса и агентское вознаграждение требуют контекста; сами слова не доказывают подкуп."
            ]
        ),
        .init(
            id: "procurement-collusion",
            titleKey: "Procurement collusion",
            descriptionKey: "Hide expressions about arranged bidding, including prevention and training discussions. Ordinary tenders and technical specifications remain separate.",
            terms: [
                "сговор на торгах", "картельный сговор", "картельное соглашение", "прикрывающая заявка",
                "подставной участник", "подставная заявка", "заточенное техзадание", "заточить ТЗ",
                "договорной тендер", "bid rigging", "cover bidding", "bid rotation"
            ],
            contextualExamples: [
                "Другой участник подаёт заведомо непроходную цену ради видимости конкуренции.",
                "Сегодня выигрывает одна компания, следующий лот заранее оставляют другой.",
                "Технический участник, карманный поставщик и заточка ТЗ требуют проверки контекста."
            ]
        ),
        .init(
            id: "commercial-metrics",
            titleKey: "Commercial metrics and pricing",
            descriptionKey: "Hide the listed business metrics and pricing expressions, including public examples. This broad group does not determine whether information is confidential.",
            terms: [
                "юнит-экономика", "unit economics", "валовая маржа", "маржинальность", "себестоимость",
                "CAC", "LTV", "EBITDA", "burn rate", "кассовый разрыв", "управленческая отчётность",
                "прогноз выручки", "финансовая модель", "индивидуальная скидка"
            ],
            contextualExamples: [
                "Сколько остаётся с одного клиента после всех переменных расходов.",
                "На сколько месяцев хватит текущих денег без новых продаж.",
                "Runway, воронка, пайплайн, процент и скидка имеют обычные значения и требуют контекста."
            ]
        ),
        .init(
            id: "planned-transactions",
            titleKey: "Investments and corporate transactions",
            descriptionKey: "Hide the listed investment and transaction expressions, including announced deals and educational examples. Confidentiality is a user choice.",
            terms: [
                "сделка M&A", "слияние и поглощение", "term sheet", "due diligence", "инвестиционный раунд",
                "pre-money", "post-money", "cap table", "опционный пул", "оценка компании",
                "продажа доли", "закрытие сделки", "data room", "shareholder agreement"
            ],
            contextualExamples: [
                "Покупатель получает контроль, а основатели оставляют меньшую часть капитала.",
                "Стороны обсуждают цену входа инвестора до объявления рынку.",
                "Раунд, доля, оффер и закрытие сами по себе могут относиться к другим темам."
            ]
        ),
        .init(
            id: "employee-compensation",
            titleKey: "Employee compensation",
            descriptionKey: "Hide listed pay and employment-package expressions, including published salary ranges and general policy discussions. Ordinary offers and grades need context.",
            terms: [
                "зарплата", "заработная плата", "зарплатная вилка", "компенсационный пакет",
                "salary review", "пересмотр зарплаты", "оклад сотрудника", "годовой бонус сотрудника",
                "выходное пособие", "retention bonus", "оплата труда", "индексация зарплаты"
            ],
            contextualExamples: [
                "Кандидату обещают фиксированную часть и выплату по итогам года.",
                "После повышения грейда сотруднику пересматривают ежемесячную сумму.",
                "Оклад, премия, бонус и грейд имеют другие значения; без контекста они не добавляются."
            ]
        ),
        .init(
            id: "personal-health",
            titleKey: "Health and medical information",
            descriptionKey: "Hide listed medical expressions, including denials and general medical discussions. This topic setting is separate from identifying a person's name.",
            terms: [
                "медицинский диагноз", "история болезни", "лист нетрудоспособности", "курс лечения",
                "медицинское заключение", "психиатрический диагноз", "сведения о здоровье",
                "больничный лист", "врачебная тайна", "состояние здоровья", "результат медицинского анализа",
                "назначенный препарат"
            ],
            contextualExamples: [
                "Сотрудник объясняет отсутствие назначенными врачом процедурами.",
                "Обсуждаются обследование человека, ограничения по здоровью или назначенные лекарства.",
                "Диагноз проекту, лечение сервера и анализ рынка не являются медицинскими сведениями."
            ]
        )
    ]

    static func group(id: String) -> SensitiveBusinessGroup? {
        groups.first { $0.id == id }
    }
}
