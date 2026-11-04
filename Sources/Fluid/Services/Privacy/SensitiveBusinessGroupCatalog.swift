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
    static let version = "sensitive-business-groups-ru-v2-conversational"
    static let maximumCatalogTerms = 128
    static let defaultSelectedGroupIDs: Set<String> = []

    static let groups: [SensitiveBusinessGroup] = [
        .init(
            id: "illicit-remuneration",
            titleKey: "Bribes and illicit remuneration",
            descriptionKey: "Clean the listed expressions from text, including quotations and denials. Ambiguous words such as rollback or gratitude need context. A match does not establish misconduct.",
            terms: [
                "дать на лапу",
                "давать на лапу",
                "брать на лапу",
                "получать откаты от поставщиков",
                "получить откат за контракт",
                "закладывать откаты в цену",
                "заложить откат в цену",
                "откат за контракт",
                "откат за поставку",
                "откат с заказа",
                "взятка",
                "взяточник",
                "взяточничество",
                "коммерческий подкуп",
                "незаконное вознаграждение",
                "подкуп должностного лица",
                "illegal kickback"
            ],
            contextualExamples: [
                "Сколько нужно занести, чтобы проверку закрыли? Кому передать деньги?",
                "Сколько процентов с заказа вернёте лично мне после оплаты? Платёж за это в договоре не указываем.",
                "Вопрос с разрешением решим, а вы меня потом отдельно отблагодарите.",
                "За эту подпись ему лично причитается процент. В договоре этого не будет.",
                "Мы вас не обидим: после нужного решения передадим деньги через знакомого.",
                "На словах это назвали премией, но платить просили лично за допуск к заказу.",
                "Одни и те же слова могут быть обычной речью: занести документы, поблагодарить команду, обсудить законную комиссию.",
                "Откат обновления относится к программе. Разговорные неологизмы вроде «откатничал» требуют отдельных форм: морфологический словарь их может не знать."
            ]
        ),
        .init(
            id: "procurement-collusion",
            titleKey: "Procurement collusion",
            descriptionKey: "Clean expressions about arranged bidding from text, including prevention and training discussions. Ordinary tenders and technical specifications remain separate.",
            terms: [
                "тендер для массовки",
                "участник тендера для массовки",
                "подставной участник",
                "подставная заявка",
                "договорной тендер",
                "заточить ТЗ под поставщика",
                "ТЗ заточено под одну компанию",
                "заточить техзадание под поставщика",
                "техзадание заточено под одну компанию",
                "сговор на торгах",
                "картельный сговор",
                "прикрывающая заявка",
                "bid rigging",
                "cover bidding",
                "bid rotation",
                "картельное соглашение"
            ],
            contextualExamples: [
                "Победителя уже выбрали. Ты просто подайся для массовки, цену поставь выше нашей.",
                "На этот тендер идём мы, а следующий заранее оставляем вам. Друг другу цену не сбиваем.",
                "Нужна ещё одна заявка, чтобы с виду была конкуренция. Выигрывать ей не надо.",
                "Техничку попросили податься только для количества. Сама «техничка» может означать и документацию.",
                "В ТЗ вписали параметры нашего товара, чтобы остальные поставщики не прошли.",
                "Выигрываем по очереди по предварительной договорённости. Без неё чередование побед не означает сговор.",
                "Отказаться от участия предлагают за отдельную выплату. Без договорённости обычный отказ от тендера ничего не доказывает.",
                "ТЗ заточено под безопасность: это может быть обычная техническая задача. Нужен контекст ограничения конкуренции.",
                "Независимые победы по очереди, помощь с заявкой и уточнение характеристик товара сами по себе не означают сговор."
            ]
        ),
        .init(
            id: "commercial-metrics",
            titleKey: "Commercial metrics and pricing",
            descriptionKey: "Clean the listed business metrics and pricing expressions from text, including public examples. This broad group does not determine whether information is confidential.",
            terms: [
                "маржа",
                "маржинальность",
                "себестоимость",
                "выручка",
                "чистая прибыль",
                "кассовый разрыв",
                "работать в минус",
                "увеличить маржинальность",
                "сократить операционные расходы",
                "финансовая модель",
                "индивидуальная скидка",
                "unit economics",
                "CAC",
                "LTV",
                "EBITDA",
                "burn rate",
                "юнит-экономика",
                "валовая маржа",
                "управленческая отчётность",
                "прогноз выручки"
            ],
            contextualExamples: [
                "После закупки, рекламы и доставки с продажи остаётся совсем немного. Сколько именно?",
                "На сколько месяцев хватит денег, если больше не придёт ни одного клиента?",
                "Сколько стоит привлечь одного покупателя и сколько он потом приносит?",
                "Сейчас каждый заказ убыточный. Нужно поднять цену, иначе деньги закончатся.",
                "Крупному клиенту можем уступить ещё пять процентов, но наружу эту цену не показываем.",
                "Выйти в плюс по деньгам и выйти в плюс по рейтингу звучит похоже, но только первый разговор относится к финансовым показателям.",
                "Минус в формуле и положительный результат теста без разговора о деньгах не относятся к коммерческим показателям."
            ]
        ),
        .init(
            id: "planned-transactions",
            titleKey: "Investments and corporate transactions",
            descriptionKey: "Clean the listed investment and transaction expressions from text, including announced deals and educational examples. Confidentiality is a user choice.",
            terms: [
                "поднять раунд инвестиций",
                "поднимать раунд инвестиций",
                "закрыть инвестиционный раунд",
                "закрывать инвестиционный раунд",
                "продать долю в компании",
                "продавать долю в компании",
                "продажа доли в компании",
                "продать компанию",
                "продажа компании",
                "инвестиционный раунд",
                "оценка компании",
                "term sheet",
                "due diligence",
                "cap table",
                "data room",
                "опционный пул",
                "сделка M&A",
                "слияние и поглощение",
                "pre-money",
                "post-money",
                "shareholder agreement"
            ],
            contextualExamples: [
                "Поднимаем раунд, потом закрываем его с инвесторами. Без этой связи обычный раунд в игре ничего не говорит о сделке.",
                "Деньги привлекаем в обмен на часть компании. До объявления обсуждаем это только с партнёрами.",
                "Инвестор хочет войти по более низкой оценке. Сколько процентов ему готовы отдать?",
                "Основатель собирается выйти из бизнеса и продать свою часть.",
                "Покупателю откроем документы после соглашения о неразглашении. До сделки детали не выносим.",
                "Закрыть раунд в игре, продать долю квартиры и договориться о цене обычной покупки могут относиться к другим темам."
            ]
        ),
        .init(
            id: "employee-compensation",
            titleKey: "Employee compensation",
            descriptionKey: "Clean listed pay and employment-package expressions from text, including published salary ranges and general policy discussions. Ordinary offers and grades need context.",
            terms: [
                "зарплата",
                "заработная плата",
                "зарплатная вилка",
                "зарплата на руки",
                "белая зарплата",
                "серая зарплата",
                "черная зарплата",
                "зарплата в конверте",
                "белая часть зарплаты",
                "серая часть зарплаты",
                "пересмотр зарплаты",
                "повысить зарплату",
                "повышать зарплату",
                "оклад сотрудника",
                "годовой бонус сотрудника",
                "выходное пособие",
                "retention bonus",
                "salary review",
                "компенсационный пакет",
                "оплата труда",
                "индексация зарплаты"
            ],
            contextualExamples: [
                "Сколько будет на руки после всех вычетов? И какая часть проходит официально?",
                "На бумаге одна сумма, а остальное доплачивают отдельно. Речь именно об оплате сотруднику.",
                "После испытательного срока обещали пересмотреть деньги, но пока оставили прежний оклад.",
                "Часть платят фиксированно, а премию обещают по итогам года.",
                "Выдать документы на руки, белая часть фотографии и бонус в игре не являются обсуждением оплаты труда."
            ]
        ),
        .init(
            id: "personal-health",
            titleKey: "Health and medical information",
            descriptionKey: "Clean the listed medical expressions from text, including denials and general medical discussions. This group is separate from identifying a person's name.",
            terms: [
                "принимать таблетки",
                "пить таблетки",
                "принимать лекарство",
                "назначить лекарство",
                "пройти медицинское обследование",
                "пройти чекап",
                "лежать в больнице",
                "медицинский диагноз",
                "история болезни",
                "больничный лист",
                "лист нетрудоспособности",
                "медицинское заключение",
                "результат медицинского анализа",
                "анализ крови",
                "курс лечения",
                "психиатрический диагноз",
                "назначенный препарат",
                "сведения о здоровье",
                "врачебная тайна",
                "состояние здоровья"
            ],
            contextualExamples: [
                "Врач сказал, что со мной, и назначил лечение. На работе подробности рассказывать не хочу.",
                "Терапию продолжаю каждый день. Название препарата и результаты обследования оставим между нами.",
                "После процедуры какое-то время работать не смогу. Обсудим ограничения и больничный.",
                "Разговор о том, как лечить сервер, поставить диагноз проекту или анализировать рынок, не является медицинскими сведениями."
            ]
        )
    ]

    /// Extra complete dictionary seeds enable the corresponding supported topic.
    /// They are not unconditional literal rules for a selected expression group.
    static func semanticSeeds(for group: SensitiveBusinessGroup) -> [String] {
        group.terms + (group.id == "illicit-remuneration" ? ["откат"] : [])
    }

    static func group(id: String) -> SensitiveBusinessGroup? {
        groups.first { $0.id == id }
    }
}
