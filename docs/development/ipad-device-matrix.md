# Модели iPad для Pichi Voice

Состояние модельного ряда проверено на 12 октября 2026 года. В таблицах перечислены 45 поколений и размеров: 20 моделей с 2021 года и 25 более старых. Wi-Fi/Cellular, цвет и региональный номер не создают отдельный вычислительный профиль. [Определение моделей Apple](https://support.apple.com/en-us/108043).

**Рекомендация архитектора:** iPad Air M1 с 8 ГБ RAM как целевой минимум полного сценария, iPad 9 как устройство для проверки нижней границы. Все оценки предварительные: Pichi Voice ещё не проходил аппаратные тесты iPad. «Рекомендую» означает разумный кандидат для разработки, а не гарантию непрерывной фоновой ASR, диаризации или точности названий препаратов.

Обычный режим сохраняет аудио и текст; тяжёлый финальный разбор можно выполнить при возвращении в приложение. Строгий режим никогда не пишет аудиофайлы, даже временные, и требует фоновой ASR, которая успевает обработать ограниченную очередь. Поэтому два режима имеют разный порог допуска.

## Модели с 2021 года

Все перечисленные модели поддерживают актуальную iPadOS 27. [Совместимость Apple](https://support.apple.com/guide/ipad/ipad-models-compatible-with-ipados-27-ipad213a25b2/ipados). Накопители указаны в ГБ, если отдельно не указано ТБ. RAM устройства не равна памяти, доступной одному приложению.

| Модель | Год | Чип | RAM | Экран | Накопитель | Разъём | Обычный режим | Строгий режим и говорящие |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [iPad 9](https://support.apple.com/en-us/111898) | 2021 | A13 | 3 ГБ* | 10,2″ LCD | 64/256 | Lightning | Кандидат с лёгкой ASR, финальная обработка отдельно. | Только после теста Tiny; диаризация и параллельная презентация под вопросом. |
| [iPad 10](https://support.apple.com/en-us/111840) | 2022 | A14 | около 4 ГБ* | 10,9″ LCD | 64/256 | USB-C, USB 2 | Кандидат Tiny/Base. | Ограниченный запас RAM, нужен замер. |
| [iPad A16](https://support.apple.com/en-us/122240) | 2025 | A16 | 6 ГБ* | 11″ LCD | 128/256/512 | USB-C, USB 2 | Хороший бюджетный кандидат. | Проверить CPU ASR и ресурсы диаризации. |
| [mini 6](https://support.apple.com/en-us/111886) | 2021 | A15 | 4 ГБ* | 8,3″ LCD | 64/256 | USB-C, 5 Гбит/с | Кандидат с ограничениями. | Небольшой экран и RAM; аппаратный тест обязателен. |
| [mini A17 Pro](https://support.apple.com/en-us/121456) | 2024 | A17 Pro | 8 ГБ* | 8,3″ LCD | 128/256/512 | USB-C, 10 Гбит/с | Хороший компактный кандидат. | Хороший бюджет памяти; CPU/thermal проверить. |
| [Air 5](https://support.apple.com/en-us/111887) | 2022 | M1 | 8 ГБ | 10,9″ LCD | 64/256 | USB-C, 10 Гбит/с | Рекомендуемый минимум полного сценария. | Первый целевой профиль для проверки. |
| [Air 11 M2](https://support.apple.com/en-us/119894) | 2024 | M2 | 8 ГБ | 11″ LCD | 128/256/512/1 ТБ | USB-C, 10 Гбит/с | Рекомендую. | Хороший кандидат с проверкой background CPU. |
| [Air 13 M2](https://support.apple.com/en-us/119893) | 2024 | M2 | 8 ГБ | 13″ LCD | 128/256/512/1 ТБ | USB-C, 10 Гбит/с | Рекомендую, больше места для UI. | Такой же вычислительный профиль; проверить расход батареи. |
| [Air 11 M3](https://support.apple.com/en-us/122241) | 2025 | M3 | 8 ГБ | 11″ LCD | 128/256/512/1 ТБ | USB-C, 10 Гбит/с | Рекомендую. | Хороший кандидат. |
| [Air 13 M3](https://support.apple.com/en-us/122242) | 2025 | M3 | 8 ГБ | 13″ LCD | 128/256/512/1 ТБ | USB-C, 10 Гбит/с | Рекомендую, большой экран. | Хороший кандидат. |
| [Air 11 M4](https://support.apple.com/en-us/126471) | 2026 | M4 | 12 ГБ | 11″ LCD | 128/256/512/1 ТБ | USB-C, 10 Гбит/с | Рекомендую с запасом. | Больший запас памяти, поведение ОС проверить. |
| [Air 13 M4](https://support.apple.com/en-us/126472) | 2026 | M4 | 12 ГБ | 13″ LCD | 128/256/512/1 ТБ | USB-C, 10 Гбит/с | Рекомендую с запасом. | Больший запас памяти и пространства UI. |
| [Pro 11, поколение 3](https://support.apple.com/en-us/111897) | 2021 | M1 | 8/16 ГБ** | 11″ LCD, 120 Гц | 128/256/512/1/2 ТБ | Thunderbolt/USB 4 | Рекомендую, включая 8 ГБ. | Хороший целевой профиль. |
| [Pro 12,9, поколение 5](https://support.apple.com/en-us/111896) | 2021 | M1 | 8/16 ГБ** | 12,9″ mini-LED, 120 Гц | 128/256/512/1/2 ТБ | Thunderbolt/USB 4 | Рекомендую, большой экран. | Хороший целевой профиль. |
| [Pro 11, поколение 4](https://support.apple.com/en-us/111842) | 2022 | M2 | 8/16 ГБ** | 11″ LCD, 120 Гц | 128/256/512/1/2 ТБ | Thunderbolt/USB 4 | Рекомендую. | Запас для дальнейших моделей, проверить реальную память. |
| [Pro 12,9, поколение 6](https://support.apple.com/en-us/111841) | 2022 | M2 | 8/16 ГБ** | 12,9″ mini-LED, 120 Гц | 128/256/512/1/2 ТБ | Thunderbolt/USB 4 | Рекомендую. | Хороший кандидат. |
| [Pro 11 M4](https://support.apple.com/en-us/119892) | 2024 | M4 | 8/16 ГБ** | 11″ OLED, 120 Гц | 256/512/1/2 ТБ | Thunderbolt/USB 4 | Рекомендую с запасом. | Сильный кандидат; ускорители в фоне не гарантированы. |
| [Pro 13 M4](https://support.apple.com/en-us/119891) | 2024 | M4 | 8/16 ГБ** | 13″ OLED, 120 Гц | 256/512/1/2 ТБ | Thunderbolt/USB 4 | Рекомендую с запасом. | Сильный кандидат. |
| [Pro 11 M5](https://support.apple.com/en-us/125406) | 2025 | M5 | 12/16 ГБ** | 11″ OLED, 120 Гц | 256/512/1/2 ТБ | Thunderbolt/USB 4 | Максимальный запас в текущем списке. | Хороший кандидат; для первого MVP избыточен. |
| [Pro 13 M5](https://support.apple.com/en-us/125407) | 2025 | M5 | 12/16 ГБ** | 13″ OLED, 120 Гц | 256/512/1/2 ТБ | Thunderbolt/USB 4 | Максимальный запас, большой экран. | Хороший кандидат; не обязателен для MVP. |

\* Apple не публикует RAM обычного iPad и mini. Значения являются номинальной оценкой по первичным аппаратным измерениям: [iPad 9, 2,87 ГБ видимой памяти](https://browser.geekbench.com/v6/cpu/19122185), [mini 6, 3,77 ГБ](https://browser.geekbench.com/v6/cpu/19149439), [A16, 5,78 ГБ](https://browser.geekbench.com/v6/cpu/10997260), [mini A17 Pro, 7,72 ГБ](https://browser.geekbench.com/v6/cpu/18496969). В [разборе iFixit iPad 10](https://documents.cdn.ifixit.com/pdf/ifixit/guide_155642_en.pdf) чип памяти определён как вероятные 4 ГБ. Это не сертификация каждой комплектации; при приёмке измеряем своё устройство.

\** Pro M1/M2: 8 ГБ с 128/256/512 ГБ, 16 ГБ с 1/2 ТБ. Pro M4: 8 ГБ с 256/512 ГБ, 16 ГБ с 1/2 ТБ. Pro M5: 12 ГБ с 256/512 ГБ, 16 ГБ с 1/2 ТБ. RAM этих моделей и Air с M-чипами опубликована Apple в соответствующих спецификациях.

## Более старые поколения

Все эти устройства выходят за исходный возрастной ориентир. «Исключить из MVP» означает решение о поддерживаемом парке, а не утверждение, что устройство неспособно записывать звук. Deployment target предлагается iPadOS 18 для прямого переиспользования текущего SwiftUI renderer. Модель с iPadOS 26 может технически запускать такой target, хотя уже не получает последнюю основную ОС; устройства с максимумом iPadOS 17 его не проходят.

| Модель | Год | Чип | RAM, ГБ* | Экран | Накопитель, ГБ | Последняя основная ОС сейчас | Оценка |
| --- | --- | --- | --- | --- | --- | --- | --- |
| [iPad 1](https://support.apple.com/en-us/112438) | 2010 | A4 | 0,25 | 9,7″ | 16/32/64 | iOS 5 | Исключить из MVP. |
| [iPad 2](https://support.apple.com/en-us/111990) | 2011 | A5 | 0,5 | 9,7″ | 16/32/64 | iOS 9 | Исключить из MVP. |
| [iPad 3](https://support.apple.com/en-us/111992) | 2012 | A5X | 1 | 9,7″ | 16/32/64 | iOS 9 | Исключить из MVP. |
| [iPad 4](https://support.apple.com/en-us/111993) | 2012 | A6X | 1 | 9,7″ | 16/32/64/128 | iOS 10 | Исключить из MVP. |
| [iPad 5](https://support.apple.com/en-us/111960) | 2017 | A9 | 2 | 9,7″ | 32/128 | iPadOS 16 | Не проходит предлагаемый OS target. |
| [iPad 6](https://support.apple.com/en-us/111957) | 2018 | A10 Fusion | 2 | 9,7″ | 32/128 | iPadOS 17 | Исключить из MVP: возраст и небольшой бюджет. |
| [iPad 7](https://support.apple.com/en-us/111911) | 2019 | A10 Fusion | 3 | 10,2″ | 32/128 | iPadOS 18 | Исключить из стартового парка. |
| [iPad 8](https://support.apple.com/en-us/118451) | 2020 | A12 | 3 | 10,2″ | 32/128 | iPadOS 26 | Только экспериментальная поддержка лёгкого профиля. |
| [Air 1](https://support.apple.com/en-us/112020) | 2013 | A7 | 1 | 9,7″ | 16/32/64/128 | iOS 12 | Исключить из MVP. |
| [Air 2](https://support.apple.com/en-us/112017) | 2014 | A8X | 2 | 9,7″ | 16/32/64/128 | iPadOS 15 | Исключить из MVP. |
| [Air 3](https://support.apple.com/en-us/111939) | 2019 | A12 | 3 | 10,5″ | 64/256 | iPadOS 26 | Только экспериментальная поддержка. |
| [Air 4](https://support.apple.com/en-us/111905) | 2020 | A14 | 4 | 10,9″ | 64/256 | iPadOS 27 | Для уже имеющихся устройств условный кандидат, нужен тест. |
| [mini 1](https://support.apple.com/en-us/111978) | 2012 | A5 | 0,5 | 7,9″ | 16/32/64 | iOS 9 | Исключить из MVP. |
| [mini 2](https://support.apple.com/en-us/112019) | 2013 | A7 | 1 | 7,9″ | 16/32/64/128 | iOS 12 | Исключить из MVP. |
| [mini 3](https://support.apple.com/en-us/112018) | 2014 | A7 | 1 | 7,9″ | 16/64/128 | iOS 12 | Исключить из MVP. |
| [mini 4](https://support.apple.com/en-us/112002) | 2015 | A8 | 2 | 7,9″ | 16/32/64/128 | iPadOS 15 | Исключить из MVP. |
| [mini 5](https://support.apple.com/en-us/111904) | 2019 | A12 | 3 | 7,9″ | 64/256 | iPadOS 26 | Только экспериментальная поддержка; тесный UI. |
| [Pro 12,9, поколение 1](https://support.apple.com/en-us/112024) | 2015 | A9X | 4 | 12,9″ | 32/128/256 | iPadOS 16 | Не проходит предлагаемый OS target. |
| [Pro 9,7](https://support.apple.com/en-us/111965) | 2016 | A9X | 2 | 9,7″ | 32/128/256 | iPadOS 16 | Не проходит предлагаемый OS target. |
| [Pro 10,5](https://support.apple.com/en-us/111927) | 2017 | A10X | 4 | 10,5″ | 64/256/512 | iPadOS 17 | Исключить из стартового парка. |
| [Pro 12,9, поколение 2](https://support.apple.com/en-us/111964) | 2017 | A10X | 4 | 12,9″ | 64/256/512 | iPadOS 17 | Исключить из стартового парка. |
| [Pro 11, поколение 1](https://support.apple.com/en-us/111974) | 2018 | A12X | 4/6 по конфигурации | 11″ | 64/256/512/1024 | iPadOS 26 | Только экспериментальная поддержка. |
| [Pro 12,9, поколение 3](https://support.apple.com/en-us/111979) | 2018 | A12X | 4/6 по конфигурации | 12,9″ | 64/256/512/1024 | iPadOS 26 | Только экспериментальная поддержка. |
| [Pro 11, поколение 2](https://support.apple.com/en-us/118452) | 2020 | A12Z | 6 | 11″ | 128/256/512/1024 | iPadOS 27 | Условный кандидат, если уже есть в парке. |
| [Pro 12,9, поколение 4](https://support.apple.com/en-us/111977) | 2020 | A12Z | 6 | 12,9″ | 128/256/512/1024 | iPadOS 27 | Условный кандидат, если уже есть в парке. |

\* RAM старых поколений не опубликована Apple в потребительских спецификациях. Для пограничных устройств: [iPad 8, измерение](https://browser.geekbench.com/v6/cpu/18518582), [Air 4, измерение](https://browser.geekbench.com/v6/cpu/19145763), [Air 3, iFixit](https://www.ifixit.com/Teardown/iPad+Air+3+Teardown/121759), [mini 5, iFixit](https://www.ifixit.com/Teardown/iPad+Mini+5+Teardown/121589), [Pro 2018, 4 ГБ](https://www.ifixit.com/Teardown/iPad+Pro+11-Inch+Teardown/115457), [вариант Pro 2018 с 5,54 ГБ видимой памяти](https://browser.geekbench.com/v5/compute/2315801), [Pro 2020, iFixit](https://www.ifixit.com/Device/iPad_Pro_12.9%22_4th_Gen).

Другие первичные разборы RAM: [iPad 1](https://www.ifixit.com/Teardown/Apple+A4+Teardown/2204), [iPad 2](https://www.ifixit.com/Teardown/iPad+2+Wi-Fi+EMC+2415+Teardown/5071), [iPad 3](https://www.ifixit.com/Teardown/iPad+3+4G+Teardown/8277), [iPad 4](https://www.ifixit.com/News/3676/ipad-4-teardown), [iPad 5](https://www.ifixit.com/Teardown/iPad+5+Teardown/85098), [iPad 6](https://www.ifixit.com/Teardown/iPad+6+Teardown/105416), [iPad 7](https://www.ifixit.com/Teardown/iPad+7+Teardown/126291), [Air 1](https://www.ifixit.com/News/5544/ipad-air-teardown), [Air 2](https://www.ifixit.com/Teardown/iPad+Air+2+Teardown/30592), [mini 1](https://www.ifixit.com/News/3663/ipad-mini-teardown), [mini 2](https://www.ifixit.com/Teardown/iPad+Mini+2+Teardown/19374), [mini 3](https://www.ifixit.com/Teardown/iPad+Mini+3+Wi-Fi+Teardown/30628), [mini 4](https://www.ifixit.com/Teardown/iPad+Mini+4+Teardown/48891), [Pro 9,7](https://documents.cdn.ifixit.com/pdf/ifixit/guide_60939_en.pdf), [Pro 10,5](https://www.ifixit.com/Teardown/iPad+Pro+10.5-Inch+Teardown/92534), [Pro 12,9 2015](https://www.ifixit.com/Teardown/iPad+Pro+12.9-Inch+Teardown/52599), [Pro 12,9 2017](https://browser.geekbench.com/v6/cpu/19157402).

Исторические пределы основных OS сопоставлены по спискам Apple: [iPadOS 16](https://support.apple.com/en-mk/103267), [17](https://support.apple.com/en-by/120949), [18](https://support.apple.com/en-bh/104986), [26](https://support.apple.com/en-gb/guide/ipad/ipad213a25b2/ipados), [27](https://support.apple.com/guide/ipad/ipad-models-compatible-with-ipados-27-ipad213a25b2/ipados), [iOS 12](https://support.apple.com/en-gb/103049), [iPadOS 15](https://support.apple.com/de-de/109032), [старые обновления iOS 9/10](https://support.apple.com/en-mn/103179). Последняя основная ОС не равна последней security patch.

## Параметры, определяющие выбор

| Параметр | Значение для Pichi Voice |
| --- | --- |
| RAM | Запись, распознавание, диаризация и Keynote/PowerPoint конкурируют за память. 8 ГБ является целевым бюджетом, а не доказанным техническим минимумом. |
| CPU в фоне | Нужен sustained real-time factor меньше 1 с запасом на запись и презентацию. Размер model file не доказывает этот результат. |
| Накопитель | 128/256 ГБ удобнее для моделей и истории с аудио. При строгом режиме аудиофайлы не создаются; RAM остаётся ограниченной. |
| Экран | 11″ удобно для ежедневного ношения; 13″ удобно для истории рядом с документом. Mini требует компактной композиции. OLED/120 Гц не является требованием ASR. |
| Микрофоны | В 2021+ обычный iPad/Air/mini имеет два, Pro M1/M2 пять, Pro M4/M5 четыре. Их количество не доказывает качество удалённого голоса или диаризации. |
| USB | USB-C удобнее для внешнего микрофона и питания через хаб. Thunderbolt не нужен для базовой записи. Маршруты и питание проверяются аппаратно. |
| Место | GPS/GNSS есть в Wi-Fi + Cellular. В Wi-Fi версии предусматриваем ручное место и доступные системные сетевые оценки. [Пример Apple](https://support.apple.com/en-us/122240). |
| Батарея и нагрев | Заявленная автономность обычного browsing не предсказывает длительность ASR. Измеряем 30/60 минут реальной одновременной работы. |
| Background lifecycle | Даже M5 может получить audio interruption или OS termination. Запись, preview text и строгая приватность имеют явные состояния остановки/пропуска. |

Для первой аппаратной матрицы: iPad 9/A13, iPad mini 6/A15, Air M1 и один iPhone. Проверяем foreground/background/lock, презентацию со звуком и без, mixed RU/EN, термины, пиковую память, батарею, thermal state и отсутствие audio-file writes при выключенном аудио.
