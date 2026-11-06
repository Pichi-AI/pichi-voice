# Наблюдение звонков и mute: обзор платформ

Дата исследования: 6 ноября 2026. Область: локальная запись на Mac, обнаружение звонка и состояния собственного микрофона. Доступность клиента, возможность захватить его звук и достоверность mute являются разными свойствами. Этот документ не обещает поддержку всех существующих ВКС.

## Решение и текущая реализация

По запросу владельца продукта сохраняется локальный подход. Один `MeetingCallObservationService` управляет обнаружением звонков, активными наблюдателями микрофона, общим расписанием и пассивным PTT. Платформенная логика вынесена в отдельные модули. Общий контракт находится в [PichiCallObservation](../../Vendor/PichiCallObservation/README.md); добавление сервиса не требует изменения ASR, writer или координатора транскрибации.

Микрофон при начале попытки считается включённым. Явные переходы mute/unmute запоминаются; скрытая панель, недоступное AX или отсутствие нового кадра не создают состояние «неизвестно» в продукте и не меняют сохранённое состояние. Key-down только помечает возможный PTT, а допуск открывается по подтверждённому интерфейсом unmute. Key-up ограничивает временный допуск по времени исходного события. Потеря фокуса/слушателя закрывает только известный временный допуск; это предложенный защитный default реализации, не отдельное подтверждённое пользователем решение.

В первой реализации зарегистрированы 12 профилей: 9 активных профилей и 3 отключённых исследовательских. Это не 12 проверенных клиентов. Zoom и Meet используют ранее реализованные адаптеры; их включение в новую композицию требует отдельной проверки. Остальные активные профили пока имеют синтетическую проверку контракта и предварительные RU/EN селекторы. Они находятся в feature-ветке, а не в установленном приложении.

| Платформа | Что есть в этом изменении | Что ещё нужно для приёмки |
| --- | --- | --- |
| Zoom | Нативный адаптер AX, небольшой crop и HUD, Space PTT; существующий detector | Короткая проверка новой композиции, обычный и временный unmute |
| Google Meet | Семантический web-профиль; существующий rendered-адаптер Chrome | Chrome, затем отдельно Safari/PWA; вкладки и PTT |
| Microsoft Teams | Native/web семантический профиль, Option+Space | Текущий Mac-клиент, self-control ancestry, hold/transfer |
| Cisco Webex | Native/web семантический профиль, Space | Mac-клиент, sharing toolbar, гарнитура |
| Slack huddles | Native/web профиль | Отдельное окно huddle и главный интерфейс |
| Telegram | Native `ru.keepcoder.Telegram` и web-профиль | Telegram Desktop является другим клиентом и отдельно не заявлен |
| Яндекс Телемост | Web-профиль `.ru`/`.com` | Нативный bundle ID и реальные локализованные controls |
| Контур.Толк | Web-профиль `ktalk.ru` и поддомены | Нативный клиент, Safari, корпоративные домены |
| МТС Линк | Web-профили актуальных и legacy event origins | Нативный клиент, новый/старый интерфейс, разделение комнаты и настроек |
| VK Teams | Отключённый исследовательский профиль | Подтвердить identities и собственные controls |
| TrueConf | Отключённый исследовательский профиль | Preanswer/connected/hold, native controls |
| Linphone | Отключённый исследовательский профиль | Call-leg identity, mute/hold/consultative transfer |

В Teams/Webex сохранены прежние эвристики окно+аудио; они ещё не стали гарантированными семантическими детекторами. У существующих web-платформ также сохранён ограниченный legacy URL fallback. Новые web-профили требуют положительного признака фазы звонка. Простого открытого сайта недостаточно.

## Источники сигналов

| Источник | Для чего подходит | Чего не доказывает |
| --- | --- | --- |
| NSWorkspace и CGWindow metadata | Запуск/выход процесса, принадлежность и геометрия окна | Звонок может жить в фоне; окно dialer может оставаться после окончания |
| CoreAudio device/process activity | Работа I/O, связь helper с владельцем, вспомогательное начало/окончание | Работающий input не означает сетевую передачу или unmute. [Apple](https://developer.apple.com/documentation/coreaudio/audiohardwareprocess/isrunninginput) |
| Accessibility controls | Собственный mic control, Leave/Answer/Resume/Rejoin, действительный web origin | Нет универсальных стабильных ID, отсутствует документированная верхняя граница задержки |
| Маленький локальный crop/HUD | Дополнительное подтверждение видимого перехода, когда AX неполон | Цвет сам по себе не является состоянием; нужен self-control и свежая геометрия |
| Пассивные клавиатурные события | Привязка временного unmute и граница отпускания | Нажатие не доказывает, что приложение приняло команду, настройка включена или ведущий разрешил unmute |
| API приложения/АТС | Возможный отдельный модуль с явным lifecycle/call ID | Серверная запись/CTI не гарантируют наличие локального медиапотока на Mac |

CoreAudio process taps захватывают output процесса, а не произвольный внутренний send-path после mute. Поэтому они не заменяют наблюдение собственного mute. [Apple taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps).

## Западные ВКС и мессенджеры

Последний столбец ниже является инженерным планом из изученных свойств, а не результатом нативной приёмки.

| Продукт | Подтверждённая особенность | Следующий модуль/случай |
| --- | --- | --- |
| Zoom | Space PTT зависит от настроек; shortcuts могут переназначаться. [Zoom](https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0067050) | Self toolbar + HUD; host-forced mute, скрытая панель, compact window |
| Meet | Space PTT включается отдельно. [Google](https://support.google.com/meet/answer/16175468?co=GENIE.Platform%3DDesktop&hl=en) | Origin + connected controls, смена вкладки и окна, PiP |
| Teams | Mac PTT использует Option+Space; chat/stage могут менять обработку. [Microsoft](https://support.microsoft.com/en-us/teams/meetings/mute-and-unmute-your-mic-in-microsoft-teams) | Отличать mute от hold, device settings и moderation |
| Webex | Space временно размьючивает; запрет ведущего и headset controls влияют на результат. [Cisco](https://help.webex.com/article/n94aj5j) | Self control в разных окнах; не переносить Windows shortcuts на Mac |
| Slack | Cmd+Shift+Space переключает mute, это не PTT. [Slack](https://slack.com/help/articles/201374536-Slack-keyboard-shortcuts-and-commands/) | Huddle window и self toolbar; не открывать допуск по shortcut |
| Telegram | Первая версия профиля разделяет Answer и End call; реальный AX контракт ещё не подтверждён | Раздельно проверить нативный Mac-клиент, Telegram Desktop и web |
| Signal | Есть обычное окно и свёрнутый call view; mic/device control документирован. [Signal](https://support.signal.org/hc/en-us/articles/5369785769370-Calling-options-Switch-camera-microphone-or-view) | Отдельные selectors для compact/full; Shift+M является toggle. [Shortcuts](https://support.signal.org/hc/en-us/articles/360036517511-Signal-Desktop-Keyboard-Shortcuts) |
| Discord | Пользовательский, серверный mute, deafen и права канала различаются. [Discord](https://support.discord.com/hc/en-us/articles/360045138471-Discord-Voice-and-Video-Troubleshooting-Guide) | Эффективное разрешение передачи, пользовательский PTT, voice channel lifecycle |
| Jitsi / Whereby | В существующем detector есть URL-эвристики; нового подтверждённого mute-модуля здесь нет | Hosted и self-hosted origins отдельно; connected controls обязательны для нового модуля |
| FaceTime / WhatsApp / RingCentral / 8x8 | Кандидаты следующей инвентаризации; текущие bundle IDs, AX и режимы не проверены этим исследованием | Не заявлять поддержку по названию/маркетингу. Сначала подтвердить локальный Mac endpoint и controls |

Публичные обсуждения помогают выбирать отрицательные сценарии. Например, [обсуждение Slack shortcuts](https://www.reddit.com/r/Slack/comments/134yn6l) описывает конфликт глобальных сочетаний, но это старый пользовательский отзыв, не текущий технический контракт. Исследование [Are You Really Muted?](https://arxiv.org/abs/2204.06128) относится к 2022 году и показывает, почему UI mute и доступ приложения к микрофону нужно разделять; оно не устанавливает поведение версий 2026 года.

## Российские ВКС

| Продукт | Подтверждённая поверхность | Механизм и границы |
| --- | --- | --- |
| Яндекс Телемост | Browser и отдельный desktop, macOS 12+. [Требования](https://yandex.com/support/yandex-360/customers/telemost/desktop/en/start/requirements) | Web origin + Leave/self-mic; нативный модуль требует отдельной проверки |
| Контур.Толк | Native, browser, SIP; macOS 12+. [Требования](https://support.kontur.ru/talk/41117-texnicheskie_trebovaniya) | Учитывать browser-to-native handoff и tenant subdomain. Версии Electron и управление AirPods меняются. [Release notes](https://support.kontur.ru/talk/83559-versii_2026) |
| МТС Линк | Browser/native, настройки устройства и комнаты различаются. [Инструкция](https://help.mts-link.ru/article/23254) | `my.mts-link.ru`, event origins и старый Webinar; layout новой комнаты иной. [Новая комната](https://help.mts-link.ru/article/26674) |
| VK Teams / VK Звонки | Корпоративные calls, guest browser join, собственный и чужой mute. [Руководство](https://biz.mail.ru/docs/on-premises/vk-teams/call-user-guide/call-user-guide.pdf) | Раздельные identities продуктов; tenant origins, self-control ancestry. Не объединять VK Teams и все продукты VK одним host substring |
| TrueConf | Настройки mic/camera доступны до ответа. [Incoming calls](https://trueconf.ru/docs/client/ru/incoming-calls/) | Answer/connected нужно различать; preanswer meter не подтверждает звонок |
| Р7 Команда | Есть Mac ARM64/x64 distributions. [Загрузки](https://support.r7-office.ru/download/team/) | Нативная идентификация плюс корпоративный guest origin. [Гостевые ссылки](https://support.r7-office.ru/team/general_maintenance_r7_team/guest-link/) |
| IVA Connect | Desktop и гостевое подключение документированы. [Desktop guide](https://iva.ru/docs/desktop/latest/ug/introduction.html) | Первая задача: подтвердить Mac-вариант, bundle ID и self controls; не считать маркетинговую страницу звонком |
| VideoMost | Web и требования к клиентам описаны отдельно. [Требования](https://www.videomost.com/help/software-and-hardware-requirements) | Hosted/self-hosted room identities; отдельные prejoin и participant moderation |
| Vinteo | Desktop v3 имеет отдельное руководство. [Vinteo](https://wiki.vinteo.com/wiki/Vinteo_Desktop_v3) | Не путать удалённое управление аппаратным терминалом с локальным endpoint Mac |
| DION | Native shortcuts, PiP и версии интерфейса документированы. [Controls](https://faq.dion.vc/ru/users/functionality_in_the_room) | Cmd+Shift+M является toggle; Space после фокуса на кнопке не доказывает PTT. Отдельный compact view |
| Jazz / СберJazz | В очередь исследования; актуальные macOS/AX свойства здесь не подтверждены | Сначала документация текущего клиента и доступный native/web endpoint |

Изменение раскладки является реальным эксплуатационным риском. Нельзя хранить абсолютную экранную координату кнопки. Модуль должен находить и проверять control внутри принадлежащего звонку окна, после перемещения заново получать геометрию. Физический mute гарнитуры может не совпадать с программной кнопкой и требует отдельного сигнала, если продукт обещает отображать именно аппаратное состояние. [Контур о внешнем оборудовании](https://kontur.ru/talk/spravka/54105-otvety_na_voprosy_o_tolke_kotorye_zadayut).

## Софтфоны и корпоративная телефония

| Продукт | Что установлено источниками | План наблюдения |
| --- | --- | --- |
| 3CX | Web/PWA и актуальный Mac-клиент; pop-out dialer способен оставаться после звонка. [Web client](https://www.3cx.com/user-manual/web-client/), [dialer](https://www.3cx.com/blog/releases/web-client-pop-out-dialer/) | Ringing/connected/hold/end controls; отличить local softphone от CTI управления DECT/deskphone |
| Zoiper 5 | Windows/macOS/Linux. [Products](https://www.zoiper.com/en/products) | Lines, compact view, mute/hold/transfer отдельно; старый PDF не доказывает сегодняшние AX IDs |
| Linphone | Mac-клиент и явный hold/resume. [Install](https://www.linphone.org/en/docs/install-linphone/), [Hold](https://www.linphone.org/en/docs/hold-call/) | Call-leg scope для consultative transfer; общий window ID недостаточен |
| Bria | Mac/Windows; device test существует вне звонка. [Guide](https://docs.counterpath.com/docs/DeskUG/clients/UserGuides/Desktop/intro/deskUserGuideIntro.htm) | Не использовать test meter как call signal; self mute, hold и selected line |
| MicroSIP | Windows distribution. [Downloads](https://www.microsip.org/downloads) | Не заявлять native Mac-поддержку. Wine/remote desktop требуют отдельного продукта/адаптера |
| PhonerLite | В очередь исследования, Mac native не подтверждён | Нельзя автоматически переносить Windows softphone в Mac matrix |
| MANGO Talker | Есть macOS вариант. [MANGO](https://prod.mango-office.ru/support/7_podderzhka/11_faq/1_virtualnaya-ats/8_softfon_m_talker/) | Установленный bundle ID, active line, consult/hold, compact controls |
| Zadarma | Mac-клиент для Apple M-series, SIP/АТС. [Zadarma](https://zadarma.com/ru/support/instructions/macosx/zadarma/) | Проверить native AX, transfer и переключение CallerID отдельно от звонка |
| NOVOFON | Отдельная Mac-инструкция. [NOVOFON](https://novofon.com/instructions/calls/novofon-macos/) | Самостоятельный модуль/identity, не alias Zadarma по сходству интерфейса |
| UIS / CoMagic | Operator workplace для Windows/macOS. [Руководство](https://www.uiscom.ru/upload/iblock/6e5/f4gd0m5w1f6i8ir3d0pw6zgwlxv4t2fh.pdf) | Разделить CRM карточку и локальный медиа endpoint, active line и hold |
| Телфин | Собственный desktop softphone документирован для Windows; для Mac предложены сторонние SIP-клиенты. [Телфин](https://lib.telphin.ru/applications-and-extensions/third-party-softfones) | На Mac детектировать реальный Zoiper/другой endpoint, а не бренд АТС |
| Sipuni | Есть приложение, браузерное расширение и отдельные softphone-инструкции. [Sipuni](https://doc.sipuni.com/articles/654-1502-657--prilozhenie-sip-uni/) | Подтвердить выбранный Mac endpoint/режим; CRM click-to-call не означает локальный PCM |
| Oktell | Корпоративный комплекс с отдельной технической документацией. [Описание](https://ftp.oktell.ru/upload/Tehnicheskoe_opisanie_Oktell.pdf) | Сначала endpoint inventory и OS support; не делать вывод о Mac по наличию АТС |
| Dialpad | Desktop Mac и web/PWA; Meetings отдельный клиент. [Downloads](https://help.dialpad.com/hc/en-us/articles/54784837567131-Download-Dialpad), [Meetings](https://help.dialpad.com/hc/en-us/articles/55267972407323-Use-the-Meetings-Desktop-App) | Отдельные модули call/meeting surfaces, плавающая панель и hold |
| Aircall | Workspace регистрируется обработчиком телефонных ссылок. [Aircall](https://support.aircall.io/en-gb/articles/10375395051293) | Открытая tel-ссылка не connected; подтвердить call phase и self mic в актуальном Mac-клиенте |
| CloudTalk | Есть desktop phone downloads. [CloudTalk](https://www.cloudtalk.io/download-app/) | Подтвердить текущий Mac package и controls, не брать состояние из dashboard/истории |

Публичный [отзыв 3CX о переключении PWA/DECT](https://www.3cx.com/community/threads/3cx-app-pwa-auto-switches-from-phone-to-dect.138345/) полезен как сценарий CTI, но не является подтверждением дефекта всех установок. В режиме deskphone media может вообще не проходить через Mac. Для такого случая локальный recorder не должен обещать обе стороны звонка.

## Риски и поведение

| Случай | Реализованная защита / оставшаяся работа |
| --- | --- |
| Hidden toolbar, окно перемещено/перекрыто | Последнее состояние latch сохраняется; поиск по принадлежащему окну, не абсолютной координате |
| Старый AX/capture callback после stop | Generation и delivery fence; stop join не допускает запись в новую попытку |
| Key-up пришёл поздно или модификатор отпущен первым | Временная граница берётся из acquisition timestamp; modifier release закрывает owned chord |
| PTT отключён в клиенте, запрет ведущего, ввод Space в чат | Key-down не открывает допуск без положительного self-unmute |
| Потеря фокуса/событий при PTT | Закрывается известный временный grant, постоянный unmute сохраняется |
| Другой участник, host moderation, меню | Нужны self identifiers/ancestry. Предварительные label-only профили требуют native подтверждения и могут быть недостаточны |
| Несколько окон, звонков, call legs | Не выбирать при явной неоднозначности; запись pin-ит окно/document. Несколько legs внутри одного окна требуют отдельного scoped adapter |
| App relaunch/PID reuse, смена вкладки/PWA | Проверяются владелец PID, window/document, URL host boundaries; новый процесс не становится прежним mute observer |
| Ringing/prejoin/device test/hold | Независимые фазы; работа mic и meter не connected. Hold сохраняет звонок, ограничивает transmission |
| Native/browser handoff | Не удваивать источники по одной ссылке; после pin не переключать recorder на другую поверхность автоматически |
| Hardware mute / AirPods / другая гарнитура | UI может отражать не всё. Проверка устройства и синхронизации вне первой версии generic adapter |
| UI язык/обновление | Сейчас предварительные RU/EN labels; неизученный язык даёт отсутствие evidence, не эвристический перевод |
| Заблокированный экран, permission loss, suspend | Сохранение/завершение наблюдения по существующему lifecycle; нет обхода системных разрешений |
| CPU/память | 2 s discovery cadence, 250 ms active cadence; AX discovery до 1 Hz, конечные бюджеты/cache/queue. Фактический CPU ещё не измерен |

Локальная UI-детекция имеет задержку, для которой платформы не дают универсального контракта. Существующий admission gate проверяет исключение и возобновление на реальном PCM writer boundary, но не превращает наблюдение UI в доказательство нулевой задержки для любой ВКС. Потерянный переход нельзя восстановить по отсутствующей иконке. Это существенная граница выбранной default-on политики.

## Очередь поставки

1. Закончить проверку объединённого сервиса на Zoom/Meet, сохранив текущие streaming/admission контракты.
2. Native self-control acceptance для Teams, Slack и Telegram; убрать label ambiguity там, где нужны identifiers/ancestor scope.
3. Web/native Телемост, Контур.Толк, МТС Линк. Отдельно проверить корпоративные origins и browser-to-native handoff.
4. VK Teams, TrueConf, Р7, DION и прочие российские ВКС по доступности реальных клиентов.
5. Linphone/Zoiper/3CX как первая SIP группа: добавить проверенную call-leg семантику, затем MANGO, Zadarma/NOVOFON, UIS и остальные endpoints.

На каждый следующий модуль достаточно своего контракта, focused synthetic tests, одного writer exclusion/resume check при изменении admission и короткой проверки реального клиента. Полная регрессия моделей/всех устройств на каждое добавление платформы не требуется. Приёмка должна фиксировать версию клиента, OS, язык, источник сигнала, проверенные состояния и реальные ограничения.

Внутренние запросы команды сверены отдельно в разрешённом Slack. Частные цитаты, имена заказчиков, номера телефонов, SIP endpoints и учётные данные в этот репозиторий не перенесены. Обсуждения bot/transcript integrations не считаются автоматически запросом на native Mac-модуль Pichi Voice.
