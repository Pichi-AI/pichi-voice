# Установка демо на iPad через собственный Mac

Этот маршрут предназначен для личного iPad и бесплатной Personal Team владельца Mac. Проверка самого маршрута на Mac Ратибора ещё требуется. Инструкция сверена с исходниками `50e2e1f9` и документацией Apple 18 октября 2026 года. Финальный commit приложения и результат проверки экспортера выдаются отдельно при доставке демо. Нельзя подменять их этой исходной ревизией.

## До установки

Нужны:

- Модель iPad, версия iPadOS и свободное место. Приложение требует iPadOS 17.0 или новее; год выпуска сам по себе недостаточен.
- Модель Mac, процессор, версия macOS, установленная версия Xcode и свободное место. Проверенный проектом набор инструментов: Xcode 27.0 на Apple Silicon. Apple указывает для Xcode 27 macOS Tahoe 26.6 или новее. Другие сочетания требуют отдельной сборки, их совместимость здесь не подтверждена. Сверить [таблицу Xcode](https://developer.apple.com/xcode/system-requirements) с фактической iPadOS.
- Полный Xcode с компонентами iOS, Git, Python 3 и кабель для передачи данных, подходящий к Mac и iPad. Одних Command Line Tools недостаточно.
- Собственный Apple Account, вход в который владелец выполняет сам в Xcode. Пароль, коды подтверждения и приватные ключи никому не пересылать.
- Доступ к приватному репозиторию `Pichi-AI/pichi-voice` под собственной учётной записью GitHub либо отдельная согласованная доставка исходников. Доступ к GitHub и Apple Account не связан.
- Интернет для первой установки зависимостей, подписи и моделей. Запас места нужен и на Mac для Xcode/сборки, и на iPad для моделей, распаковки и Core ML cache. Около 507 MiB модельных файлов не является полным требованием к свободному месту.

Если iPad управляется организацией, заранее проверить, разрешены ли Developer Mode, установка приложений разработчика, микрофон и AirDrop/экспорт. Не обходить ограничения управления устройством.

**До обновления существующей установки сохранить актуальные встречи, настройки и профиль собственного голоса. Не удалять приложение ради исправления подписи.** Установка с новым bundle ID создаёт отдельную установку и не переносит старую историю автоматически. Для повторных установок сохранять тот же team и bundle ID.

## Бесплатная подпись

[Apple разрешает локальное тестирование через Personal Team](https://developer.apple.com/help/account/basics/about-your-developer-account). Профиль действует семь дней; после истечения приложение нужно снова собрать и установить. Ограничения: три устройства, три приложения на устройстве и до десяти App ID. Перед демо проверить фактический срок профиля. Такая установка не даёт TestFlight и не делает чужую подписанную сборку пригодной для этого iPad.

Это не универсальный установочный файл. Компьютер владельца получает исходники и подписывает приложение его собственной Personal Team для его устройства. Не импортировать сертификаты, ключи, provisioning profiles или профиль голоса другого человека.

## Получить точную версию

Разработчик передаёт полный финальный SHA и доступную ветку. В командах ниже сначала заменить значение `PICHI_DEMO_COMMIT` на этот SHA. Не собирать автоматически меняющийся `main` перед показом.

```bash
git clone https://github.com/Pichi-AI/pichi-voice.git
cd pichi-voice
git fetch origin
PICHI_DEMO_COMMIT='FULL_FINAL_COMMIT_FROM_HANDOFF'
git show --no-patch --oneline "$PICHI_DEMO_COMMIT"
bash scripts/dev/new-worktree.sh ratibor-demo "$PICHI_DEMO_COMMIT"
```

Перейти в **каталог, напечатанный последней командой**, затем:

```bash
bash scripts/dev/assert-worktree.sh
bash scripts/dev/setup.sh
git rev-parse HEAD
xcodebuild -version
open Fluid.xcodeproj
```

`setup.sh` выполняет переносимые проверки и настройку read-only upstream. Он не устанавливает модели и не доказывает, что приложение собрано. `scripts/dev/mobile.sh` предназначен для симулятора с отключённой подписью, а не для установки на настоящий iPad.

### Если разработчик передал архив исходников

Этот маршрут не требует доступа к приватному GitHub. Получить отдельно полный SHA исходной ревизии и SHA-256 архива, сверить архив через `shasum -a 256 /absolute/path/to/source.zip`, распаковать в новый пустой каталог. Архив не содержит `.git`, моделей, записей, настроек, профиля голоса или подписи. Сохранить исходный SHA и хеш архива во внешнем manifest рядом с архивом, не выдавать локальный commit за оригинальный.

В распакованном каталоге создать только локальный репозиторий и рабочую копию. Эти команды не меняют глобальную Git identity и ничего не публикуют:

```bash
git init -b main
git add .
git -c user.name='Local Demo' -c user.email='demo@example.invalid' commit -m 'Import delivered demo sources'
PICHI_LOCAL_SOURCE_COMMIT="$(git rev-parse HEAD)"
PICHI_DEMO_ORIGINAL_REVISION='FULL_ORIGINAL_COMMIT_FROM_VERIFIED_HANDOFF'
bash scripts/dev/new-worktree.sh ratibor-demo "$PICHI_LOCAL_SOURCE_COMMIT"
```

Затем перейти в напечатанный worktree и выполнить `assert-worktree.sh` и `setup.sh`, как выше. Локальный commit отличается от переданного SHA, хотя исходные файлы совпадают. В параметре `PICHI_SOURCE_REVISION` при сборке ниже явно передать **оригинальный полный SHA из проверенного handoff**, вместо локального `git rev-parse HEAD`. Сохранять собственные team и bundle ID, собирать Release и запускать без отладчика по тем же шагам. Архив не является подписанной сборкой и не переносит уже существующие встречи.

## Подключить iPad и настроить Xcode

1. Подключить разблокированный iPad кабелем. Подтвердить доверие к Mac на iPad и выполнить сопряжение в Xcode, если оно запрошено.
2. В `Xcode > Settings > Apple Accounts` войти в собственный Apple Account. Должна появиться собственная Personal Team.
3. Открыть target **PichiVoiceMobile**, раздел `Signing & Capabilities`. Включить `Automatically manage signing`, выбрать собственную команду. Не выбирать одноимённый macOS target или тестовые targets.
4. Для первой отдельной установки задать уникальный Bundle Identifier, например `com.example.ratibor.pichivoicedemo`, заменив пример на собственный уникальный идентификатор. Общий `ai.pichi.voice.mobile` может быть недоступен другой команде. Локальные изменения подписи не публиковать в репозиторий.
5. Выбрать scheme **PichiVoiceMobile** и именно подключённый iPad в качестве destination. Дождаться подготовки устройства и установки необходимых компонентов Xcode.
6. На iPad включить `Настройки > Конфиденциальность и безопасность > Режим разработчика`, если Xcode запросит. Потребуются перезапуск и подтверждение на разблокированном iPad. Если пункт ещё не появился, сначала завершить сопряжение с Xcode. См. [инструкцию Apple](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device).

Свой Apple Account и автоматическую подпись Xcode использует для регистрации устройства и профиля. См. [запуск на физическом устройстве](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices). Ошибку подписи нужно прочитать в Xcode; удалять приложение, сбрасывать разрешения или отзывать сертификаты без разбора причины нельзя.

## Собрать обычный Release и запустить без отладчика

В `Product > Scheme > Edit Scheme > Run > Info` выбрать **Release** и отключить `Debug executable`. В настройках проекта задать Derived Data и package checkouts внутри текущего worktree, не использовать общий изменяемый каталог другой сессии. Выполнить `Product > Run`, не `Product > Test`.

После первого успешного запуска закончить запуск из Xcode, затем открыть приложение его иконкой на iPad. Перед настоящим показом отсоединить кабель и повторить короткую запись. Нужна обычная сборка приложения, без `.xctest` и диагностических переменных окружения.

Для разработчика ниже приведён эквивалент сборки в отдельном каталоге. Значения берутся из собственного Xcode и фактически подключённого устройства. Эти команды здесь **не выполнялись** на Mac Ратибора. Флаги provisioning разрешают Xcode создавать нужные signing assets в его аккаунте; выполняет их сам владелец при установке.

```bash
PICHI_DEMO_TEAM='YOUR_PERSONAL_TEAM_ID'
PICHI_DEMO_BUNDLE='YOUR_UNIQUE_BUNDLE_ID'
PICHI_DEMO_DEVICE='YOUR_CONNECTED_IPAD_ID'
PICHI_DEMO_REVISION="${PICHI_DEMO_ORIGINAL_REVISION:-$(git rev-parse HEAD)}"

xcodebuild -project Fluid.xcodeproj -scheme PichiVoiceMobile \
  -configuration Release -sdk iphoneos \
  -destination "id=$PICHI_DEMO_DEVICE" \
  -derivedDataPath "$PWD/.build/demo-release/DerivedData" \
  -clonedSourcePackagesDirPath "$PWD/.build/demo-release/SourcePackages" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$PICHI_DEMO_TEAM" \
  PRODUCT_BUNDLE_IDENTIFIER="$PICHI_DEMO_BUNDLE" \
  PICHI_SOURCE_REVISION="$PICHI_DEMO_REVISION" build

PICHI_DEMO_APP="$PWD/.build/demo-release/DerivedData/Build/Products/Release-iphoneos/PichiVoiceMobile.app"
codesign --verify --deep --strict "$PICHI_DEMO_APP"
find "$PICHI_DEMO_APP" -name '*.xctest'
```

Последний поиск должен быть пустым. Проверить bundle ID, `AppSourceRevision`, team, устройство и срок профиля, зафиксировать проверенную копию и её хеши. Установка только когда нет активной записи или обработки:

```bash
xcrun devicectl device install app --device "$PICHI_DEMO_DEVICE" "$PICHI_DEMO_APP"
```

Не использовать uninstall, очистку контейнера или замену новых данных старым backup. После установки сравнить встречи/настройки/голос с актуальным состоянием до неё. Не пересобирать и не переподписывать работающую копию во время проверки.

## Подготовить модели и настройки заранее

Это настройка внутри приложения после установки, на Wi-Fi. Не приносить на демо устройство, где модели ещё скачиваются.

1. `Настройки > Распознавание речи`: скачать **Pichi GigaAM v3**, затем выбрать `Use Model` / «Использовать модель», если модель не выбрана. Для этого русского демо штатная загрузка использует **GigaAM v3 E2E CTC INT8 без EOU-головы**. Сохранённый внутренний ID `gigaam-v3-eou` оставлен для совместимости настроек, а точную модель определяет fingerprint артефакта. Другие модели не устанавливать «на всякий случай».
2. `Настройки > Запись`: язык русский; включить определение участников и **определение участников во время записи**. Скачать ресурсы участников и дождаться готовности. Зарегистрированный потоковый профиль использует **Nemotron fast128 FP16, CPU**, а для собственного голоса отдельно загружает **legacy WeSpeaker v2 Core ML**. **fast32 W8A8 относится к обработке после записи**, не подменять им потоковый профиль.
3. `Настройки > Запись > Мой голос`: сам Ратибор в тихой комнате читает текст естественным голосом 15-20 секунд. Нажать Stop и **Save** после принятия образца. Убедиться, что показано сохранённое состояние. Чужой образец не использовать. Сохранять профиль **до начала** проверяемой встречи.
4. `Настройки > Приватность`: выключить **Save audio recordings**; включить **Redact sensitive data**, дождаться подготовки локальной PII-модели и убедиться, что переключатель включён. На новой установке нельзя полагаться на значения по умолчанию.
5. Завершить все загрузки и пробный запуск до отключения интернета. Не менять модель или профиль внутри текущей встречи.

Модельная карта выше сверена с регистрацией и дескрипторами ревизии `9414bbe1`. Публичные веса загружаются отдельно и не входят в архив исходников. В [Notices](../../Sources/Fluid/Resources/Notices) сохранены точные pinned-источники и атрибуция: GigaAM использует MIT, A1 INT8 использует Apache-2.0 с отдельным раскрытием нерешённых вопросов происхождения обучающих данных NEREL, веса Nemotron используют OpenMDW-1.1, legacy WeSpeaker использует CC-BY-4.0. Apache-2.0 notice Swift runtime не заменяет лицензию весов Nemotron. При передаче исходников сохранять весь каталог Notices и исходный GPL-3.0 [LICENSE](../../LICENSE); при включении самих модельных материалов также сохранять применимые лицензии, атрибуцию и сведения об их преобразованиях. Эти документы не подтверждают точность на любом iPad или полную очистку прав на все обучающие данные.

## Репетиция полного сценария на целевом iPad

Записать фактическую модель устройства, iPadOS, commit, bundle ID, настройки, время старта и остановки. При организованных тестах сохранять native кадры каждую секунду от старта до конца через [capture-mobile-frames.py](../../scripts/dev/capture-mobile-frames.py), все кадры оставлять локально, анализировать изменившиеся и отдельно учитывать пропуски.

- Сначала 2-3 минуты: говорит Ратибор, затем другой человек, затем снова Ратибор. Проверить появление текста, собственного голоса и отдельных участников. Добавить длительную паузу, после неё продолжить. Проверить прокрутку старого текста и ручное имя участника.
- Использовать только вымышленные ФИО, телефон и email. Проверить очистку в расшифровке, сохранность вручную заданных имён участников, затем результат после Stop в истории. PII-модель может ошибаться; это функциональная проверка примеров, а не гарантия удаления любых персональных данных.
- Во время отдельной записи перейти в **ту презентацию/CRM, которую будут показывать**. Продолжать говорить несколько минут, вернуться и проверить слова, произнесённые именно в фоне. Не воспроизводить аудио внутри приложения как способ поддерживать его в фоне. Не смахивать приложение из переключателя и не перезагружать iPad.
- После загрузок повторить запись без интернета и без USB, запуская приложение иконкой. Проверить Stop, историю и открытие встречи после повторного запуска. При выключенном сохранении аудио нельзя обещать восстановление несохранённого звука после принудительного завершения процесса.
- Проверить экспорт в Files, затем передачу реальным способом AirDrop или почтой. Подготовленное мобильное дополнение даст отдельный защищённый JSON со спикерами и временами для импорта в Pichi. **Точное название пункта и доступность веб-импорта подтвердить по финальному handoff; эта исходная ревизия их не подтверждает.** Обычные TXT/внутренний JSON не считать автоматически совместимыми с новым импортом. Имена, вручную заданные пользователем, являются метаданными и могут сохраняться в экспорте.

Проверка прошла, только если видны реальные слова обеих сторон, фоновые слова не потерялись, выбранная приватность соблюдена, результат и ручное имя сохранились, файл открывается на принимающем компьютере и согласованный импорт создаёт реальную запись в веб-приложении. При ошибке сохранить экран и время, не удалять приложение и не начинать переустановку поверх активной записи.

## Что ещё нужно от владельца устройства

Точные данные iPad и Mac, установленный Xcode, доступность своего Apple Account и GitHub, кабеля и необходимых прав на управляемом iPad, время демо и используемая презентация/CRM. Подпись и работа на конкретном устройстве считаются подтверждёнными только после этой установки и репетиции, а не после чтения инструкции.

## Optional PDF presentation in the recording screen

Before starting or while a meeting records, choose **PDF Presentation** in its toolbar, then select a PDF through the standard Files picker. The native PDF viewer displays the selected PDF inside the same app. Use **Done** to return to the recording and stop it normally. The selected PDF is opened once on an owned background worker and read directly, with security access retained until the native viewer is removed. While a meeting records in an active foreground app window, the app keeps the screen awake in both its main interface and PDF viewer. Closing the PDF releases only its presentation lease; the recording window keeps its own lease until Stop, failure, disappearance or scene inactivity. The previous screen idle timer setting is restored after the last active recording window owner releases it. Navigation cancels a pending import without blocking recording controls; a cancelled parse finishes under its file lease before another import is admitted and can never reopen the viewer. The app does not copy the document into meeting storage or retain it for later. Audio retention and sensitive data settings still belong to the meeting captured before the PDF was opened.

This is an optional foreground workflow. It does not establish that recording and inference remain reliable after switching to a separate presentation application. Test the exact device with the selected PDF, real microphone, current model and final export before a demo.

The ordinary Release background test on the 2017 A10X iPad was terminated by the operating system for its background CPU budget. That device is outside the requested 2020-and-newer range; the result does not establish the behavior of an A12 iPad. The in-app PDF route is a limited foreground alternative, not a fix or acceptance of the separate-application background scenario. Successful foreground tests alone do not make that full scenario demo-ready.
