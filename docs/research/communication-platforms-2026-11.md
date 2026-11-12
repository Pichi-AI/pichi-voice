# Наблюдение звонков и mute: обзор платформ

Исследование начато 6 ноября 2026; российские платформы повторно проверены 9 ноября. Область: локальная запись на Mac, обнаружение звонка и состояния собственного микрофона. Доступность клиента, возможность захватить его звук и достоверность mute являются разными свойствами. Этот документ не обещает поддержку всех существующих ВКС.

## Российские платформы: актуальный срез 9 ноября

Реализация модулей уже слита через [PR #114](https://github.com/Pichi-AI/pichi-voice/pull/114), merge `cd8c4c497f0715849504bc36147edcfc5dbee7a8`, и присутствует в проверенном `origin/main` `24c079e0363f552be9d16d59712b62279d3170fc`. Повторное слияние этой ветки не требуется. Таблица ниже разделяет сигналы сайта и фактическую работу Pichi. Ни один новый российский профиль этим этапом не получает обещание проверенной сквозной записи.

| Платформа и среда | Захват аудио через Pichi | Начало подключённого звонка | Собственный mute/unmute | Окончание |
| --- | --- | --- | --- | --- |
| МТС Линк web, Chrome runtime 156.0.8078.80, macOS 26.6.2 | В этом прогоне не запускался | Собственная Quick meeting, один участник, таймер и `Завершить встречу`; prejoin отсутствует | Реальные `Включить микрофон` -> `Выключить микрофон` -> `Включить микрофон`; HUD подтверждает Выкл./Вкл. Названия совпадают с действующим профилем | `Завершить для всех` + подтверждение ведут на `/aftermeeting/...`. Pichi end prompt и время его появления не проверены |
| Яндекс Телемост web | Не проверен | Своя комната осталась в `Подключение`; вложенный call frame показывает `Loading` | Кнопка микрофона присутствует до соединения, поэтому этот прогон не подтверждает mute подключённого звонка | Своя попытка завершена, подтверждён возврат home; это отмена подключения, не end принятого звонка |
| Контур.Толк web | Не проверен | Сохранённый вход работает; `Call now` требует подтверждения телефона для создания пространства | До реального звонка не проверен | До реального звонка не проверено |
| VK Teams | Не проверен | Официальный `workspacevk.com/messenger/` вернул `ERR_CERT_COMMON_NAME_INVALID`; обхода не было. Профиль остаётся выключенным | Не проверен | Не проверено |
| TrueConf | Не проверен | Официальный Create a meeting ведёт на `/login.html`. Существующий вход или пустая гостевая комната не установлены; профиль выключен | Не проверен | Не проверено |

В собственном звонке МТС видны две одинаковые self-mic кнопки: панель управления и собственный tile. DOM `data-testid` панели: `VCSControlButton.Microfone.main`; camera: `VCSControlButton.Camera.main`; окончание: `LeaveButtonDropdown.LeaveButton.Button.Button.iconButton`. Эти DOM атрибуты описывают наблюдение, но не выдаются за native AX identifiers и не добавляются в AX-профиль. Production модуль использует точные AX labels и требует положительный connected control. Prejoin и меню окончания остаются отдельными состояниями. Текущий профиль не распознаёт `/aftermeeting/` как явный `.ended`. На отсутствие положительных controls `MeetingModuleBrowserTabReader` возвращает `nil`, а общий detector запускает loss clock. Время и результат этого пути в установленной Pichi не проверялись: факт перехода сайта не подменяет сквозную проверку завершения.

Quick meeting МТС сама включила серверную запись. Камера выключена, запись приостановлена до проверяемых mute-переходов; отдельно прочитано `Запись не ведется`. Содержимое записи не исследовалось, не скачивалось и не распространялось. Установленная Pichi, её настройки и записи не менялись. Пользователь отдельно подтвердил доступность микрофона для этих одиночных тестов; контакты не приглашались. Захват PCM, отсутствие речи в muted-интервалах, задержка observer и физический PTT этим прогоном не проверялись.

В Контуре предыдущий ввод только `+1` не доказывает поддержку полного американского номера или доставку кода. Полный номер и проверка остаются действием владельца в браузере. Альтернатива - пустая комната организатора с доступом для гостей, согласно [официальному FAQ](https://kontur.ru/talk/spravka/54105-otvety_na_voprosy_o_tolke_kotorye_zadayut). Чужое рабочее приглашение не используется для теста.

Обезличенные native control subsets и снимки сохраняются вне Git. В репозиторий не переносятся room IDs, телефон, коды, учётные данные, screenshots аккаунта или аудио. Работающие Chrome helpers имеют runtime 156.0.8078.80, хотя metadata установленного bundle уже показывает 157.0.8103.50; браузер не перезапускался. Веб-сервисы не показали номер frontend release, поэтому дата наблюдения не выдаётся за версию клиента. Исторические версии native-клиентов ниже относятся только к проверке 6 ноября. Для TrueConf точный secure-fill поиск по origin не нашёл Chrome credentials; Apple provider оказался недоступен, поэтому это не доказательство отсутствия аккаунта. Новый signup, привязка SSO или чужая конференция не использовались. [Официальное руководство](https://trueconf.com/docs/client/en/calls/) требует авторизованного пользователя для создания конференции; [гостевой путь](https://trueconf.com/docs/client/en/installation/) требует существующей конференции.

## Реальные клиенты и звонки: проверка 6 ноября

По отдельному поручению выполнены настоящие одиночные звонки в Zoom, Google Meet и Teams consumer в Chrome 156.0.8078.80. Прочитаны native AX controls и DOM-атрибуты соответствующих реальных состояний. Установленное Pichi Voice этой проверкой не заменялось: это проверка источников сигналов и последующий replay их обезличенных subsets, а не приёмка всего нового recorder на всех платформах. Чужим контактам звонки и сообщения не отправлялись.

| Модуль | Фактически проверено | Результат и оставшийся пробел |
| --- | --- | --- |
| Zoom | Установленный 7.1.9 (88375), native solo call, preview, muted/unmuted tile, leave dialog | Preview имеет тот же `zm.meeting.window.main` и активный mic до `Start`. Нужна отдельная `prejoin`, а скрытая панель не означает выход. Фактически подтверждены обе смены собственного computer-audio status. Совместный новый Pichi observer ещё требует native acceptance |
| Meet | Настоящий solo call в Chrome, mic off/on, выход | Реальные `Turn on microphone` / `Turn off microphone`; `data-is-muted=true/false`, `jsname=hw0c9`. Эти labels совпали с профилем. После выхода в этом запуске сразу показана home page, отдельная Rejoin page не наблюдалась |
| Teams | Официальный подписанный native 26289.204.5281.6363 запущен до join/account UI; настоящий consumer call на `teams.live.com` | В connected call подтверждены `microphone-button`, `hangup-button`, ancestor `horizontalMiddleEnd` и mute/unmute. Prejoin имеет switch и `prejoin-join-button`. Consumer rules уточнены по этим IDs; enterprise/native connected contract отдельно не принят |
| Webex | Официальный подписанный package 46.11.0.36194, `Cisco-Systems.Spark`, native запуск | Запуск с DMG отвергается самим клиентом; проверенная копия вне volume дошла до EULA. Условия не приняты, отдельное подтверждение запрошено. Connected/mute не проверены |
| Slack | Установленный 4.53.280, native workspace UI и расположение controls | Установлен outer `AXScrollArea`, которую прежний probe пропускал. В существующем рабочем канале huddle не запускался. Собственный solo context не установлен; native UI/navigation и последующая потеря browser control ограничили этот этап. Mute labels пока не подтверждены настоящим huddle |
| Telegram | Установленный 13.2.0, Saved Messages и Recent Calls | В Saved Messages нет self-call control. Другой собеседник/тестовый endpoint не выбран, поэтому вызовы контактам не выполнялись. Call/mute contract остаётся непроверенным. В течение исследования metadata build изменился с 283459 до 283462; не считать это единым frozen runtime |
| Телемост | Авторизованный web, попытки собственного звонка; официальный Yandex-signed native 3.3.3 (10428), `ru.yandex.desktop.telemost` | Web показывал `Подключение`, `Выключить микрофон`, `Открыть экран звонка`, `Завершить звонок`, затем вернулся home без подтверждённого connected. Кнопка окончания существует ещё до соединения и недостаточна для connected. Native запуск показал window chrome без доступных call controls; native звонок не принят |
| Контур.Толк | Официальные landing/download page и production frontend asset изучены; web sign-in UI | Предварительные mic labels не подтверждены звонком. Secure fill ранее отказал с tls_verification_failed до вставки секретов, без обхода проверки. Затем владелец вошёл самостоятельно: текущий welcome UI реально прочитан. Call now и Connect to the meeting or webinar являются DIV role=button без id/data-testid. Собственный звонок и mute пока не проверены. Существование frontend strings не равно native AX support |
| МТС Линк | Официальный signed native 0.91.0 (0.91.0.3140), `ru.weteams.desktop`; ASAR metadata, chat shell и AX просмотр; web sign-in | Пакет имеет productName LinkChats и не доказывает идентичность всех старых Webinar clients. В native chat shell многие icon buttons не имеют доступного имени; собственный meeting/mute ещё не проверен. В web подтверждён вход владельца и выполнена своя Quick meeting без приглашения контактов. Реально увидены «Присоединиться к встрече», «Завершить встречу» и disabled «Включить микрофон». Connection/VPN warnings и недоступное устройство не позволили проверить mute/unmute; наличие end-event кнопки до join теперь не доказывает connected. Событие завершено для всех, после refresh подтверждено «Завершено»; вкладки задачи закрыты. Сайт сам включил cloud recording по умолчанию, микрофон не включали, частную речь не передавали, запись не скачивали и не публиковали |
| VK Teams | Официальный прежний URL перенаправляет к VK WorkSpace | Browser site safety заблокировала текущую страницу. Обход через другой браузер, HTTP или raw CDP не выполнялся. Native artifact и call contract в этом этапе не проверены |
| TrueConf | Официальный 156728951-byte DMG, Apple-signed `org.trueconf.client`, 8.5.5 / build855.176, native запуск | На реальном Welcome видны `Log in` и `Join conference`, но AX отдаёт две неназванные кнопки. В этом запуске учётная запись/ссылка тестовой конференции не использовалась; connected/mute не проверены. Модуль остаётся research-only |
| Linphone | Официальный 178312633-byte Mac DMG скачан | Mount потребовал interactive acknowledgement GPL3, автоматически не принят. Native/call не запущены; модуль остаётся research-only |

Исходные артефакты получены по ссылкам официальных поставщиков: [Teams](https://www.microsoft.com/en-us/microsoft-teams/download-app), [Webex](https://help.webex.com/article/nw5p67g), [МТС Линк](https://help.mts-link.ru/article/27291), [Телемост](https://yandex.com/support/yandex-360/business/telemost/desktop/en/installation), [TrueConf](https://trueconf.ru/downloads/mac.html), [Linphone](https://www.linphone.org/en/download/). Сохранены версии, bundle IDs, signing authorities, размеры и SHA-256. Teams PKG только распакован, install scripts не выполнялись. Пакеты и Qt/Electron resources изучались как данные, не как доказательство работающих call selectors. Полные сторонние bundles и пользовательские screenshots/сообщения в Git не включены.

Практическая дельта этого этапа: разрешён обход outer scroll viewport с прежними лимитами nodes/depth/time и исключением editor/list/history subtrees; `prejoin` запрещает ложный connected prompt и не выдумывает mic mute; binding preview откладывается до реального connected window; Teams consumer использует подтверждённые self IDs/ancestry. Zoom для hidden-toolbar connected evidence повторно использует существующий self-tile reader, только в соответствующем meeting window и только при отсутствии положительной/конфликтующей phase evidence. Новый screenshot loop не добавлен.

Дополнительно исправлены два разрыва между общей моделью и native input: при одновременно открытых preview и connected window выбранное connected окно определяет phase, а временно недоступный preview не доказывает соединение; числовые AXValue от checkbox/switch теперь доходят до `expectedValue` как ограниченные строки 0/1/2. Эти случаи проверяются отдельно от GUI-наблюдений.

Проверки кода привязаны к ревизиям: на `43088207` прошли 13 SDK tests и 17 выбранных macOS XCTest, включая writer exclusion/resume; на `f22cd6d9` после уточнения одновременных окон повторены только 3 затронутых сценария; на `0e3407d1` прошли Debug build-for-testing и отдельный native scalar-selector regression. Модели, полный ASR suite и hardware matrix не запускались. Первоначальная попытка независимого ревью не дала результата, CLI завершился HTTP429. Последующее независимое source review общей композиции выявило две гонки: delayed modifier release и queued negative при stop. Они исправлены в b6ff4518 и fd146a94 и прошли повторное чтение соответствующих дельт. Это не результат исполнения тестов или native-приёмки. Последующая интеграция подготовлена в [PR #114](https://github.com/Pichi-AI/pichi-voice/pull/114); приёмка и ограничения следующих кандидатов приведены ниже.

Старая сессия потеряла доступный browser runtime; read-only диагностика подтвердила Chrome, расширение и native-host manifest. Новая сессия подтвердила рабочее управление Chrome и выполнила описанный выше МТС probe. Поэтому прежний session-local инструментальный сбой не является текущим общим blocker. Отдельно сохраняется точный TLS отказ secure fill для Контура; пароль не вставлялся, защитные проверки не ослаблялись.

Ограничения этапа остаются существенными: не все профили подтверждены, новая общая Pichi композиция ещё не принята на реальном аудио, а наличие подписи/окна/непустой дорожки не доказывает правильную запись собственного голоса. Обнаруженная пользователем отдельная потеря собственной расшифровки Zoom исследуется в другой сессии на исходниках установленной build49 и не считается автоматически дефектом новых модулей.

## Решение и текущая реализация

По запросу владельца продукта сохраняется локальный подход. Один `MeetingCallObservationService` управляет обнаружением звонков, активными наблюдателями микрофона, общим расписанием и пассивным PTT. Платформенная логика вынесена в отдельные модули. Общий контракт находится в [PichiCallObservation](../../Vendor/PichiCallObservation/README.md); добавление сервиса не требует изменения ASR, writer или координатора транскрибации.

Микрофон при начале попытки считается включённым. Явные переходы mute/unmute запоминаются; скрытая панель, недоступное AX или отсутствие нового кадра не создают состояние «неизвестно» в продукте и не меняют сохранённое состояние. Key-down только помечает возможный PTT, а допуск открывается по подтверждённому интерфейсом unmute. Key-up ограничивает временный допуск по времени исходного события. Потеря фокуса/слушателя закрывает только известный временный допуск; это предложенный защитный default реализации, не отдельное подтверждённое пользователем решение.

В первой реализации зарегистрированы 12 профилей: 9 активных профилей и 3 отключённых исследовательских. Это не 12 проверенных клиентов. Zoom и Meet используют ранее реализованные адаптеры; их включение в новую композицию требует отдельной проверки. Остальные активные профили пока имеют синтетическую проверку контракта и предварительные RU/EN селекторы. Их наличие не означает завершённую проверку автоматического mute в текущем установленном бинарнике.

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

## Общая сборка: итог проверки 6 ноября

Подписанная сборка 54 закреплена на `c34a94d17de8d2a7a7f9d787a29bdf2ee035346e`. Она включает ручной микрофон, общий сервис/SDK, исправление route/gate build50, установленную логику волн build51 и popup corrections. Локальные группы macOS проверок прошли 26 + 4 + 9 + 3 случая на записанных в квитанциях ревизиях; изменённый echo component прошёл 9 legacy групп. Полного model/hardware прогона не было. Independent review закрыл две P1 гонки release/stop и P2 лимита дробления metadata.

В signed53 Zoom подтвердил автоматический mute/resume и Stop while muted на реальном CAF. Meet53 прервал capture после паузы: скалярный лог сохранил класс MeetingStreamingEchoAdmission.Failure, без конкретного enumcase. Найден воспроизводимый механизм: допустимые незавершённые ASR слова до паузы могут выйти за 60-секундное окно необязательного анализа эха. Исправление сохраняет исходные words/optional flags для прежнего privacy admission, не возвращает expired raw evidence в кэш и сохраняет source/cursor/resource guards. Детерминированный тест использует реальные временные границы без частного аудио или текста; native54 выдержал ручную паузу более 65 секунд, возобновление и штатный Stop без прежнего interruption.

Автоматический mute Meet54 остаётся **неподтверждённым**. Одна попытка затронула завершившуюся старую solo room, другая меняла DOM при невидимом окне Chrome на другом рабочем столе. Выбранная вкладка не доказывает onscreen window. После обычного Raise появился AXWebArea; новые AX modes, VoiceOver, browser flags и системные настройки не включались. Исследование Chromium156 подтверждает отдельные native/web activation paths, но не заменяет проверку процесса Pichi. Эти попытки не считаются PASS и сами по себе не устанавливают кодовый дефект. Последний видимый сценарий не завершён. По прямому указанию владельца 6 ноября дальнейшая ручная приёмка микрофона, popup и повторных замен выполняется им после установки; физический Space также оставлен ему. Автотесты popup добавлены, но не запускались по его выбору. Это явная граница приёмки, не подтверждение всех платформ.
