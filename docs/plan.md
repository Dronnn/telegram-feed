# TFeed — Plan

## Current shipped state (2026-03-07)

- Общая лента показывает сообщения всех выбранных каналов в одном хронологическом потоке за текущий день.
- Нижний `pull-to-refresh` запускается только вручную: пользователь тянет нижний край, пересекает порог, отпускает, и только после этого начинается полный reload ленты за сегодня.
- После нижнего refresh экран возвращается к тому же сообщению, на котором пользователь находился до обновления; новые сообщения остаются ниже текущего viewport.
- При обычном окончании скролла лента не должна сама перепривязываться к другому сообщению, подскакивать или повторно взводить догрузку истории внутри того же жеста.
- При скролле вверх старые сообщения догружаются только во время активного пользовательского жеста вверх и только когда скрытых сверху карточек осталось меньше 10; один drag даёт максимум одну маленькую догрузку и не должен визуально сдвигать уже видимое сообщение.
- При первом показе ленты и сразу после ручного reload за сегодня приложение не должно само подтягивать вчерашние или более старые сообщения до тех пор, пока пользователь сам не пошёл вверх.
- Нижняя граница дневной ленты жёстко привязана к локальной полуночи текущего дня и пересчитывается после trim/remove операций, чтобы вчерашние и более старые сообщения не возвращались в today-only режим сами по себе.
- Полный reload дня повторно добирает свежий хвост каждого выбранного канала, чтобы последнее сообщение канала не терялось в общей ленте.
- Даже если у выбранного канала сегодня нет видимых карточек, он не должен выпадать из общей истории: при уходе вверх в прошлые периоды его сообщения должны попадать в общую хронологическую ленту вместе с остальными выбранными каналами.
- Карточки используют реальные Telegram-аватары каналов, а при отсутствии фото показывают fallback с первой буквой.
- Реакции переносятся на несколько строк, карточки показывают точное время публикации до секунд.
- Poll-сообщения Telegram отфильтрованы и не создают пустые карточки.
- Остальные unsupported message types, которые приложение не умеет отрисовать, тоже не попадают в ленту как пустые карточки.
- Переход в `ChannelSheetView` идёт к конкретному target message внутри канала.
- `Clear Local Cache` теперь уничтожает локальную TDLib-базу и локальный список выбранных каналов, после чего приложение возвращается в login-state.
- Загрузка каналов больше не ограничена первыми `100` чатами: TDLib main chat list прогружается полностью, после чего список каналов и feed берут данные из полного набора.
- Лента и детали канала реагируют не только на `updateNewMessage`, но и на edits, deletions и `updateChatReadInbox`; метаданные каналов обновляются из TDLib updates.
- Если Telegram меняет или удаляет сообщение внутри media album, агрегированная карточка должна пересобираться live и в общей ленте, и в деталях канала, а не пропадать целиком до следующего reload.
- Если Telegram edit/update затрагивает уже видимый пост в общей ленте, карточка должна пересобираться внутри того же окна истории, а не выпадать из общей хронологии только потому, что пост уже старше текущего day floor.
- Входящий TDLib `updateHandler` больше не исполняет actor-isolated код напрямую на очереди `TDLibKit`: callback декодирует update вне actor isolation и только потом явно передаёт его обратно в `TDLibService`.
- `UpdateRouter` больше не делает `AsyncStream.Continuation.yield` под `NSLock`, поэтому завершение subscriber-а во время доставки update не должно ломать fan-out updates.
- Последняя ручная проверка включала и обычную сборку, и сборку со `SWIFT_STRICT_CONCURRENCY=complete`; обе прошли успешно.

Ниже остаётся исходный продуктовый и архитектурный план. Он исторический и полезен как reference, но текущее поведение приложения следует считать описанным этим блоком и `README.md`.

## Context

Нативное iOS-приложение (iOS 26+) для чтения Telegram-каналов единой лентой. Пользователь логинится Telegram-аккаунтом, выбирает каналы — и читает все их сообщения в одном хронологическом потоке. Никакого мессенджерного UI — только чистая лента контента.

Приложение будет публичным на GitHub — код должен быть чистым, качественным, хорошо структурированным. Поддержка iOS 26 Liquid Glass.

---

## 1. Требования

### Технологии
- **Swift 6 + SwiftUI**, iOS 26+ (Liquid Glass)
- **TDLibKit** (SPM, `https://github.com/Swiftgram/TDLibKit`) — Swift async/await обёртка над TDLib
- **Архитектура**: MVVM + `@Observable`
- **Concurrency**: async/await, без Combine
- **Тема**: системная (авто light/dark) с поддержкой Liquid Glass materials
- **Без push-уведомлений**, без серверной части
- **Telegram API credentials**: `api_id` + `api_hash` с my.telegram.org

### Функциональные требования
- Авторизация через Telegram (телефон + код + 2FA), дизайн в стиле Telegram
- Получение списка подписок (каналы, группы)
- Выбор каналов для ленты (в настройках)
- Единая хронологическая лента из выбранных каналов
- Отображение медиа: фото, видео, GIF, голосовые/аудио inline + fullscreen
- Показ реакций (только чтение — emoji + счётчик)
- Сохранение позиции скролла между сессиями
- Счётчик непрочитанных, обновляется при скролле
- Кнопка «вниз» (scroll to newest)
- Переход в отдельный канал поверх ленты (sheet)
- Настройки: выбор каналов, очистка кэша, выход из аккаунта

### Публичный GitHub
- Чистая архитектура, сущности отдельно
- README с описанием, скриншотами, инструкцией по сборке
- MIT лицензия

---

## 2. Экраны и навигация

Минимум экранов: **2 экрана + 2 sheet**.

```
RootView
├── if !authenticated → AuthView (fullscreen)
├── if authenticated && no channels selected → FeedView (empty state)
└── if authenticated → FeedView (лента)
                          ├── .sheet → ChannelSheetView
                          └── .sheet → SettingsView
```

### 2.1 AuthView — Авторизация (стиль Telegram)

Один экран с анимированными переходами между шагами. Дизайн максимально близок к родному Telegram.

**Шаг 1 — Номер телефона:**
```
┌──────────────────────────────────────┐
│                                      │
│                                      │
│           ┌──────────┐               │
│           │  TFeed   │               │
│           │  logo    │               │
│           └──────────┘               │
│                                      │
│        Your Phone Number             │
│                                      │
│   Please confirm your country code   │
│   and enter your phone number.       │
│                                      │
│   ┌──────────────────────────────┐   │
│   │  🇷🇺 Russia              ▾  │   │
│   ├──────────────────────────────┤   │
│   │  +7  │  999 123 45 67       │   │
│   └──────────────────────────────┘   │
│                                      │
│                                      │
│                                      │
│   ┌──────────────────────────────┐   │
│   │          Continue            │   │
│   └──────────────────────────────┘   │
│                                      │
└──────────────────────────────────────┘
```

- Иконка/лого TFeed сверху по центру (SF Symbol `antenna.radiowaves.left.and.right` в круге или кастомная)
- Заголовок «Your Phone Number» (20pt, bold)
- Подзаголовок мелким текстом (15pt, secondary)
- Селектор страны (ячейка с флагом + название + chevron)
- Поле код страны + номер (разделены вертикальной линией)
- Кнопка «Continue» внизу — filled rounded rect, акцентный цвет

**Шаг 2 — Код подтверждения:**
```
┌──────────────────────────────────────┐
│  ←                                   │
│                                      │
│           ┌──────────┐               │
│           │   📱     │               │
│           └──────────┘               │
│                                      │
│        Enter Code                    │
│                                      │
│   We've sent the code to the         │
│   Telegram app on your other device  │
│                                      │
│   ┌──────────────────────────────┐   │
│   │        Code                  │   │
│   └──────────────────────────────┘   │
│                                      │
│                                      │
└──────────────────────────────────────┘
```

- Back button (←) в верхнем левом углу
- Иконка телефона/ключа по центру
- Одно поле ввода кода (не отдельные ячейки — как в Telegram)
- Auto-submit при вводе полного кода

**Шаг 3 — 2FA пароль:**
```
┌──────────────────────────────────────┐
│  ←                                   │
│                                      │
│           ┌──────────┐               │
│           │   🔒     │               │
│           └──────────┘               │
│                                      │
│        Enter Password                │
│                                      │
│   Your account is protected with     │
│   an additional password.            │
│                                      │
│   ┌──────────────────────────────┐   │
│   │  ••••••••              👁    │   │
│   └──────────────────────────────┘   │
│                                      │
│   ┌──────────────────────────────┐   │
│   │          Submit              │   │
│   └──────────────────────────────┘   │
│                                      │
└──────────────────────────────────────┘
```

- SecureField с toggle видимости
- Кнопка «Submit»
- Обработка ошибок: красный текст под полем

**Элементы AuthView:**
- Фон: чистый системный (`Color(.systemBackground)`)
- Поля ввода: подчёркнутые снизу линией (стиль Telegram), не скруглённые прямоугольники
- Кнопка Continue/Submit: filled `.buttonStyle(.borderedProminent)`, скруглённые углы
- Иконки шагов: SF Symbols в цветном круге (60pt)
- Анимация: `.transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)).combined(with: .opacity))`
- Loading: заменяем текст кнопки на ProgressView
- Ошибки: красный label с `.font(.caption)` под полем

### 2.2 FeedView — Главный экран (лента)

Максимально пустой. Только лента и кнопка настроек.

**С сообщениями:**
```
┌──────────────────────────────────────┐
│                                 ⚙    │  ← toolbar, кнопка настроек
│                                      │
│  ┌──────────────────────────────┐    │
│  │  [av] Channel Name      · 2ч │    │
│  │                              │    │
│  │  Текст сообщения, который    │    │
│  │  может быть длинным и        │    │
│  │  многострочным...            │    │
│  │                              │    │
│  │  ┌────────────────────────┐  │    │
│  │  │                        │  │    │
│  │  │     [Фото/Видео]       │  │    │
│  │  │                        │  │    │
│  │  └────────────────────────┘  │    │
│  │                              │    │
│  │  👍 12  ❤️ 5  🔥 3           │    │
│  └──────────────────────────────┘    │
│                                      │
│  ┌──────────────────────────────┐    │
│  │  [av] Other Channel     · 1ч │    │
│  │                              │    │
│  │  Ещё одно сообщение...       │    │
│  │                              │    │
│  │  🎤 ▶ ━━━━━━━━━○━━ 1:24     │    │
│  │                              │    │
│  └──────────────────────────────┘    │
│                                      │
│                        ┌──────────┐  │
│                        │  ↓  14   │  │  ← FAB: scroll down + unread count
│                        └──────────┘  │
└──────────────────────────────────────┘
```

**Пустое состояние (каналы не выбраны):**
```
┌──────────────────────────────────────┐
│                                 ⚙    │
│                                      │
│                                      │
│                                      │
│                                      │
│           📡                         │
│                                      │
│     Select channels to read          │
│                                      │
│   Open settings and choose which     │
│   channels appear in your feed       │
│                                      │
│                                      │
│                                      │
│                                      │
└──────────────────────────────────────┘
```

**Навбар / Toolbar:**
- Без заголовка «TFeed» — максимальная пустота
- Только кнопка настроек (⚙ `gearshape`, SF Symbol) в правом верхнем углу
- Liquid Glass toolbar background

**Карточка сообщения (FeedCardView):**
- Контейнер: Liquid Glass material background, скруглённые углы 20pt
- Горизонтальные отступы карточки от краёв экрана: 16pt
- Между карточками: 12pt
- Внутри карточки: 14pt padding
- **Шапка**: аватар (круг 32pt) + название канала (semibold, 15pt) + «·» + время (13pt, secondary). Вся шапка — кнопка для открытия канала в sheet
- **Текст**: 16pt regular, поддержка bold/italic/links/code. Не обрезается
- **Медиа**: edge-to-edge внутри карточки (с учётом внутренних отступов), скруглённые углы 14pt
- **Реакции**: горизонтальная строка мелких капсул. Каждая: emoji + число (13pt), glass/translucent background, corner radius 10pt, padding 4pt/8pt
- Нет теней — Liquid Glass сам создаёт глубину

**Лента:**
- `ScrollView(.vertical)` + `LazyVStack(spacing: 12)`
- `.scrollPosition(id:)` для отслеживания позиции
- Хронологическая сортировка: старые сверху, новые внизу
- Infinite scroll вверх (подгрузка старых)
- Pull-to-refresh (`.refreshable`)
- Real-time: новые сообщения добавляются в конец

**Кнопка «вниз» + счётчик непрочитанных:**
- Floating action button, правый нижний угол (отступ 20pt от краёв)
- Капсула с Liquid Glass material: `chevron.down` + число непрочитанных (если > 0)
- Corner radius: capsule (полностью скруглённая)
- При тапе: плавный скролл к самому новому сообщению
- Исчезает когда пользователь на самом последнем сообщении
- Счётчик = количество сообщений ниже текущего viewport

### 2.3 ChannelSheetView — Отдельный канал

Sheet поверх ленты при тапе на шапку карточки.

```
┌──────────────────────────────────────┐
│  ─── (drag indicator)                │
│                                      │
│  [avatar 36pt] Channel Name    ✕     │
│                                      │
├──────────────────────────────────────┤
│                                      │
│  Те же FeedCardView, но без шапки    │
│  канала (она в заголовке sheet).     │
│                                      │
│  Проскролено к тому сообщению,       │
│  откуда пользователь перешёл.        │
│                                      │
│  ┌──────────────────────────────┐    │
│  │  Текст сообщения...          │    │
│  │  [Медиа]                     │    │
│  │  👍 12  ❤️ 5                  │    │
│  └──────────────────────────────┘    │
│                                      │
└──────────────────────────────────────┘
```

- `.sheet` с `.presentationDetents([.large])`
- Drag indicator
- Header: аватар (36pt) + название канала (17pt, semibold) + кнопка закрытия (x)
- Карточки без шапки канала — только текст, медиа, реакции, время
- При открытии: скролл к сообщению, с которого перешли
- Infinite scroll в обе стороны
- Liquid Glass material для header

### 2.4 SettingsView — Настройки

Sheet снизу, почти на весь экран.

```
┌──────────────────────────────────────┐
│  ─── (drag indicator)                │
│                                      │
│  Settings                      Done  │
│                                      │
│  🔍 Search channels...              │
│                                      │
│  CHANNELS                            │
│  ┌──────────────────────────────┐    │
│  │  [av] Tech Channel      🔘  │    │
│  │  [av] News Daily        🔘  │    │
│  │  [av] Music Vibes       ○   │    │
│  │  [av] Crypto Alert      🔘  │    │
│  │  ...                        │    │
│  └──────────────────────────────┘    │
│                                      │
│  DATA                                │
│  ┌──────────────────────────────┐    │
│  │  Clear Local Cache     →    │    │
│  └──────────────────────────────┘    │
│                                      │
│  SECURITY                            │
│  ┌──────────────────────────────┐    │
│  │  🔐 Require Face ID    ⓘ   │    │
│  └──────────────────────────────┘    │
│                                      │
│  ACCOUNT                             │
│  ┌──────────────────────────────┐    │
│  │  Log Out               🔴   │    │
│  └──────────────────────────────┘    │
│                                      │
└──────────────────────────────────────┘
```

- `.sheet` с `.presentationDetents([.large])`
- NavigationStack внутри sheet для `.searchable`
- **Секция Channels**: List со всеми подписками. Toggle (switch) для каждого канала. Аватар (28pt) + название. Поисковая строка для фильтрации
- **Секция Security**: «Require Face ID» — не toggle, а обычная ячейка с иконкой `faceid` и кнопкой info (ⓘ). При тапе показывает `.alert` с объяснением: Face ID для приложений — системная функция iOS. Инструкция: «Long-press the TFeed icon on your Home Screen, tap "Require Face ID", and choose your preference.» Кнопка «OK» закрывает алерт. Мы не реализуем Face ID сами — просто направляем пользователя к встроенной функции iOS 18+
- **Секция Data**: «Clear Local Cache» — удаляет файлы/медиа из кэша TDLib. `.confirmationDialog` перед удалением
- **Секция Account**: «Log Out» — красный текст. `.confirmationDialog` перед выходом. Выход: `TDLibService.logout()` → возврат на AuthView
- Кнопка «Done» справа сверху для закрытия
- Используем стандартный `List` с `.listStyle(.insetGrouped)` — нативный вид iOS

---

## 3. Дизайн-система

### Liquid Glass (iOS 26)
- Карточки используют glass material
- Toolbar с glass background
- FAB (кнопка вниз) с glass material
- Капсулы реакций с glass material
- Системная адаптация light/dark автоматически через materials

### Цвета
- Фон экрана: `Color(.systemBackground)`
- Карточки: glass material (адаптивный)
- Текст основной: `Color(.label)`
- Текст вторичный: `Color(.secondaryLabel)`
- Акцентный: `.tint(.blue)` (системный)
- Деструктивный: `.red`

### Типографика (системный Dynamic Type)
- Название канала: `.subheadline.weight(.semibold)` (15pt)
- Время: `.caption.weight(.regular)` (13pt)
- Текст сообщения: `.body` (16pt)
- Реакции: `.caption` (13pt)
- Бейдж непрочитанных: `.caption2.weight(.bold)` (11pt)

### Скругления
- Карточка: 20pt
- Медиа внутри карточки: 14pt
- Капсула реакции: 10pt
- Аватар: полный круг
- FAB: `.capsule`

### Отступы
- Карточка от краёв экрана: 16pt horizontal
- Между карточками: 12pt vertical
- Внутри карточки: 14pt padding
- Шапка карточки: аватар → 8pt → текст

### Иконки (SF Symbols)
- Настройки: `gearshape`
- Закрыть sheet: `xmark`
- Scroll to bottom: `chevron.down`
- Play видео/аудио: `play.fill` / `pause.fill`
- Показать пароль: `eye` / `eye.slash`
- Пустое состояние: `antenna.radiowaves.left.and.right`

---

## 4. Архитектура

### MVVM + @Observable, async/await

```
TFeedApp (@main)
  ├── AppState (@Observable) — auth state, selected channels, injected via .environment()
  ├── TDLibService (actor singleton) — async API для TDLib + update stream
  └── ViewModels (@Observable, per screen)
        ├── AuthViewModel
        ├── FeedViewModel
        ├── ChannelViewModel
        └── SettingsViewModel
```

### Структура проекта

```
TFeed/
├── TFeedApp.swift                          // @main, environment setup
├── RootView.swift                          // Auth <-> Feed routing
│
├── Core/
│   ├── AppState.swift                      // @Observable: authState, selectedChannelIDs
│   └── Constants.swift                     // api_id, api_hash (gitignored or from env)
│
├── Services/
│   ├── TDLibService.swift                  // Actor: client lifecycle, update stream
│   ├── TDLibService+Auth.swift             // sendPhone, sendCode, sendPassword, logout
│   ├── TDLibService+Chats.swift            // getChats, getChat, getChatList
│   ├── TDLibService+Messages.swift         // getChatHistory, getMessage
│   ├── TDLibService+Files.swift            // downloadFile, getFilePath
│   └── UpdateRouter.swift                  // AsyncStream<Update> broadcast to subscribers
│
├── Models/
│   ├── FeedItem.swift                      // id = FeedItemID(chatId, messageId), sortable
│   ├── FeedItemID.swift                    // Hashable, Codable composite key
│   ├── ChannelInfo.swift                   // id, title, avatarFileId
│   └── AuthStep.swift                      // enum: phoneInput, codeInput, passwordInput
│
├── ViewModels/
│   ├── AuthViewModel.swift                 // Auth state machine, async calls
│   ├── FeedViewModel.swift                 // Feed merge, pagination, unread tracking
│   ├── ChannelViewModel.swift              // Single channel messages
│   └── SettingsViewModel.swift             // Channel toggles, cache, logout
│
├── Views/
│   ├── Auth/
│   │   └── AuthView.swift                  // Telegram-style login flow
│   │
│   ├── Feed/
│   │   ├── FeedView.swift                  // Main screen: ScrollView + toolbar
│   │   ├── FeedCardView.swift              // Message card: header + text + media + reactions
│   │   ├── MediaContentView.swift          // Photo/video/GIF/voice inline rendering
│   │   └── ReactionsBarView.swift          // Horizontal reaction capsules
│   │
│   ├── Channel/
│   │   └── ChannelSheetView.swift          // Single channel sheet overlay
│   │
│   ├── Settings/
│   │   └── SettingsView.swift              // Channel toggles, cache, logout
│   │
│   └── Components/
│       ├── TdImageView.swift               // TDLib file -> AsyncImage
│       ├── VideoPlayerView.swift           // Inline + fullscreen video
│       ├── AudioPlayerView.swift           // Waveform player for voice messages
│       ├── FullscreenMediaView.swift       // Zoomable/fullscreen photo/video/GIF
│       ├── AvatarView.swift                // Circle avatar from TDLib file
│       └── FormattedTextView.swift         // TDLib FormattedText -> AttributedString
│
├── Storage/
│   ├── SelectedChannel.swift               // @Model: SwiftData entity (chatId, title, isSelected)
│   ├── Preferences.swift                   // UserDefaults wrapper: только мелкие настройки (scroll pos)
│   └── ScrollPositionStore.swift           // Save/restore FeedItemID
│
├── Extensions/
│   ├── Date+Relative.swift                 // "2h ago", "yesterday"
│   └── Message+MediaType.swift             // Helper to extract media from TDLib Message
│
├── Resources/
│   ├── Assets.xcassets/                    // App icon, accent color
│   └── Localizable.xcstrings               // Localization (EN primary)
│
├── TFeed.entitlements
└── Info.plist
```

### Поток данных

```
TDLib (C++, background thread)
    │  JSON -> TDLibKit decodes to Swift types
    ▼
TDLibService (actor singleton)
    │
    ├── AsyncStream<Update>  ->  ViewModels subscribe & filter
    │
    └── async func calls     <-  ViewModels call directly
                                    │
                                    ▼
                              @Observable properties
                                    │
                                    ▼
                              SwiftUI Views (auto re-render)
```

### Ключевые решения

| Аспект | Решение | Почему |
|---|---|---|
| State | `@Observable` macro | iOS 26, гранулярный tracking |
| Async | async/await + AsyncStream | Без Combine, современный Swift |
| TDLib threading | Actor singleton | Thread-safe без locks |
| Image cache | TDLib internal + file system | Не нужен Kingfisher |
| Navigation | `.sheet()` only | Минимум экранов |
| Persistence | SwiftData + UserDefaults | SwiftData для каналов/данных, UserDefaults только для мелких настроек (scroll pos) |
| Scroll position | `ScrollPosition` API | Нативный iOS 17+ API |
| Feed merge | Sorted array in memory | Простой, достаточно быстрый |

### Слияние ленты и управление окном сообщений

**Принцип**: в памяти хранится только «окно» сообщений вокруг текущей позиции, а не вся история. Подгрузка в обе стороны по мере скролла.

**Первый вход (нет сохранённой позиции):**
1. Параллельно `getChatHistory()` для каждого выбранного канала (последние 30 сообщений)
2. Merge в один массив, sort по `message.date` (unix timestamp)
3. Показываем с самого нового сообщения (пользователь оказывается внизу)

**Повторный вход (есть сохранённая позиция):**
1. Восстанавливаем `lastReadMessageID` из UserDefaults
2. Загружаем ~10 сообщений СТАРШЕ `lastReadMessageID` (контекст вверх)
3. Загружаем все непрочитанные сообщения НОВЕЕ `lastReadMessageID` (контент вниз)
4. Merge + sort, показываем ленту с `lastReadMessageID` по центру экрана
5. Пользователь видит: 10 старых сверху, последнее прочитанное, новые снизу

**Скролл вверх (история):**
- При приближении к верхнему краю загруженного окна -> подгружаем ещё порцию старых сообщений (по 20 из каждого канала), merge-insert в начало
- Бесконечный скролл вверх — можно уйти далеко в историю

**Скролл вниз (новые):**
- Новые сообщения добавляются в конец в real-time (подписка на `updateNewMessage`)
- Если пользователь дочитал до конца — он на самом свежем сообщении

**В рамках одной сессии:**
- Все загруженные сообщения остаются в памяти, ничего не выгружается
- Можно свободно скроллить вверх-вниз по всему загруженному диапазону

**При выходе из приложения:**
- Сохраняем ID последнего видимого сообщения как `lastReadMessageID`
- При следующем входе — окно пересоздаётся вокруг этой точки (10 вверх + новые вниз)

### Счётчик непрочитанных

- Считаем сообщения ниже текущего viewport как «непрочитанные»
- При `updateNewMessage` + пользователь не внизу -> +1
- При скролле обновляем count на основе `scrollPosition`
- FAB с `chevron.down` + badge count. Скрываем при count == 0

### Сохранение позиции скролла

1. Feed использует `.scrollPosition(id: $scrollPositionID)` с `FeedItemID`
2. `onChange(of: scenePhase)` -> при `.background` сохранить `lastReadMessageID` в UserDefaults
3. При запуске -> загрузить окно вокруг сохранённой позиции (10 старых + новые)
4. `.scrollPosition` позиционирует на `lastReadMessageID` по центру
5. Если сохранённое сообщение удалено -> скролл к ближайшему по дате

---

## 5. Процесс работы и коммиты

После каждого завершённого логического шага (не обязательно целая фаза — достаточно законченного шага, при котором приложение собирается и логически корректно):

1. Обновить `docs/plan.md` — отметить выполненные пункты (`[ ]`)
2. Записать в лог (`logs/devlog.md`) — **максимально подробно**:
   - Какой шаг выполнен (ссылка на пункт плана)
   - Какие файлы созданы/изменены (полные пути)
   - Ключевые решения и почему именно так (альтернативы, если были)
   - Проблемы, с которыми столкнулись, и как решили
   - Что конкретно делать дальше (следующий шаг)
   - Текущее состояние: собирается ли проект, что работает, что нет
   - Любой контекст, который поможет продолжить после перезапуска
3. Обновить `README.md` если появилась новая функциональность
4. Сделать локальный коммит с осмысленным сообщением

Push на GitHub пока не делаем — репозиторий на GitHub ещё не создан. Коммитим только локально.

---

## 6. Фазы реализации

### Фаза 1: Фундамент
- [x] Создать Xcode проект (iOS 26, Swift 6), добавить TDLibKit (SPM)
- [x] Настроить структуру папок (Core, Services, Models, ViewModels, Views, etc.)
- [x] Реализовать `TDLibService` — actor, client lifecycle, update handler
- [x] Реализовать `UpdateRouter` — AsyncStream broadcast
- [x] Реализовать `AppState` — auth state tracking
- [x] Реализовать `RootView` — routing между AuthView и FeedView
- [x] `Constants.swift` с api_id/api_hash (+ `.gitignore` для credentials)

### Фаза 2: Авторизация
- [x] `AuthStep` enum (phoneInput, codeInput, passwordInput) — Equatable, Hashable
- [x] `AuthViewModel` — state machine: phone -> code -> 2FA -> ready
- [x] `AuthView` — Telegram-style UI с переходами между шагами
- [x] Обработка ошибок (неверный код, rate limit, сетевые)
- [x] Loading states на кнопках
- [x] `AppState.startListening()` — auth state transitions from TDLib updates
- [x] `RootView` — TDLib initialization via `.task`

### Фаза 3: Лента (ядро)
- [x] Модели `FeedItem`, `FeedItemID`, `ChannelInfo`
- [x] `FeedViewModel` — загрузка каналов, fetch messages, merge sort
- [x] `FeedView` — ScrollView + LazyVStack, toolbar с настройками
- [x] `FeedCardView` — шапка + текст + placeholder для медиа + реакции
- [x] Infinite scroll (подгрузка старых при скролле вверх)
- [x] `.refreshable` pull-to-refresh
- [x] Подписка на `updateNewMessage` для real-time

### Фаза 4: Медиа
- [x] `TdImageView` — minithumbnail -> thumbnail -> full-size pipeline
- [x] `MediaContentView` — роутинг по типу медиа
- [x] Inline видео (thumbnail + play overlay -> AVPlayer)
- [x] GIF/animation auto-play
- [x] `AudioPlayerView` — waveform + play/pause для голосовых
- [x] `FullscreenMediaView` — fullscreen для фото/видео/GIF

### Фаза 5: Текст, реакции, UX
- [x] `FormattedTextView` — bold, italic, links, code, spoilers
- [x] `ReactionsBarView` — капсулы emoji + count, glass material
- [x] Счётчик непрочитанных + FAB «вниз»
- [x] Сохранение/восстановление scroll position

### Фаза 6: Канал и настройки
- [x] `ChannelViewModel` + `ChannelSheetView` — single channel view
- [x] `SettingsViewModel` + `SettingsView` — channel toggles, search
- [x] «Clear Local Cache» + confirmation dialog
- [x] «Log Out» + confirmation dialog + TDLib logout
- [x] Persist selected channel IDs в SwiftData (`SelectedChannel` @Model)

### Фаза 7: Polish и GitHub
- [x] Liquid Glass materials на карточках, toolbar, FAB
- [x] Пустые состояния (нет каналов, нет сообщений)
- [x] Обработка ошибок сети (no connection state)
- [x] Light/dark mode тестирование
- [x] README.md: описание, скриншоты, build instructions, лицензия
- [x] `.gitignore` (credentials, build artifacts)
- [x] Memory profiling (большие ленты, много медиа)
- [x] Scroll position persistence across app kill

---

## 7. Верификация

1. **Auth**: запуск на устройстве -> ввод номера -> код -> логин
2. **Settings**: открыть настройки -> включить 3-5 каналов -> лента заполняется
3. **Feed**: сообщения из разных каналов отсортированы хронологически
4. **Scroll persistence**: проскролить -> убить приложение -> открыть -> та же позиция
5. **Media**: фото/видео/GIF inline -> tap -> fullscreen. Голосовые: play inline
6. **Channel sheet**: tap на шапку карточки -> sheet с каналом, проскролено к сообщению
7. **Unread**: получить новые сообщения -> badge на FAB -> tap -> скролл вниз
8. **Logout**: Settings -> Log Out -> confirm -> возврат на AuthView
9. **Clear cache**: Settings -> Clear -> confirm -> медиа удалено

---

## Phase 1: Foundation - Implementation Checklist

- [x] Create Xcode project (pbxproj, workspace) with iOS 26 target, Swift 6, TDLibKit SPM
- [x] Create TFeedApp.swift - SwiftUI app entry point with AppState environment
- [x] Create RootView.swift - routing between auth states
- [x] Create Core/AppState.swift - @Observable with AuthState enum
- [x] Create Core/Constants.swift - API credentials placeholder (gitignored)
- [x] Create Models/AuthStep.swift - auth step enum
- [x] Create Services/TDLibService.swift - actor singleton wrapping TDLibKit
- [x] Create Services/UpdateRouter.swift - @MainActor AsyncStream broadcast
- [x] Create Views/Auth/AuthView.swift - placeholder
- [x] Create Views/Feed/FeedView.swift - placeholder
- [x] Create Resources/Assets.xcassets - accent color, app icon
- [x] Create TFeed.entitlements - empty skeleton
- [x] Update .gitignore - Xcode, credentials, macOS ignores

---

## Auth Hotfix Plan (2026-03-05)

- [x] По запросу пользователя код auth-фикса откатан; следующий этап — реализовать фиксы заново и перепроверить их.
- [x] Первый приоритет: устранить ошибку "код не приходит в официальный Telegram-клиент и не приходит по SMS после ввода номера"; подтвердить end-to-end на реальном номере, что код реально доходит пользователю.
- [x] Статус на 2026-03-05 (device check): пользователь подтвердил, что код все еще не приходит в официальный Telegram-клиент и не приходит по SMS.
- [x] Следующий этап: перепроверить, действительно ли Telegram сервер получает и обрабатывает `setAuthenticationPhoneNumber`/`resendAuthenticationCode` на живом номере (по логам и фактической доставке кода).
- [x] Следующий этап: проверить, не возвращается ли `authenticationCodeTypeFirebaseIos` и нужно ли отдельное поведение для него.
- [x] Следующий этап: подтвердить UX/тексты и оставить только нужные изменения.

---

## Code Review Fixes (2026-03-05)

- [x] FINDING 1: Add retry counter for Firebase auto-resend (infinite loop risk) -- CONFIRMED, fixed
- [x] FINDING 2: Combine reportCodeMissing + resendCode into sequential operation -- CONFIRMED, fixed
- [x] FINDING 3: Restore nextType guard for manual resendCode -- CONFIRMED, fixed
- [x] FINDING 4: Remove phone number digits from log output -- CONFIRMED, fixed
- [x] FINDING 5: Move print() out of describeCodeType pure function -- CONFIRMED, fixed
- [x] FINDING 6: Remove redundant per-scroll save in FeedView -- CONFIRMED, fixed
- [x] FINDING 7: Remove dead code optimizeStorage -- FALSE POSITIVE (used in SettingsViewModel)
- [x] FINDING 8: Replace appState with isStarted boolean -- CONFIRMED, fixed
- [x] FINDING 9: Extract repeated transition in AuthView -- CONFIRMED, fixed
- [x] FINDING 10: Replace force-unwrap on FileManager URLs -- CONFIRMED, fixed
- [x] FINDING 11: Pass actual pushTimeout for Firebase countdown -- CONFIRMED, fixed
- [x] FINDING 12: Add Firebase fallback note to README -- CONFIRMED, fixed

---

## Additional Review Fixes (2026-03-05)

- [x] FINDING 1: Race condition in auth bootstrap - AsyncStream continuation registered asynchronously in Task, could miss initial TDLib update -- CONFIRMED, fixed (create stream synchronously before Task)
- [x] FINDING 2: Error-handling gap in setParameters() - silently returns on guard failures instead of throwing -- CONFIRMED, fixed (added TDLibServiceError enum, throw on failure)
- [x] FINDING 3: Logic regression in resend gating - 30s fallback for timeout<=0 delays valid immediate resend -- CONFIRMED (partially), fixed (allow immediate canResendCode when timeout<=0)
- [x] FINDING 4: Race condition in resend flow - manual resend and Firebase auto-resend not coordinated -- CONFIRMED, fixed (cancel firebaseResendTask in resendCode and reportCodeMissingAndResend)

---

## Bug 4: Intercept t.me links in message cards (2026-03-05)

- [x] Step 1: FormattedTextView — add `onTelegramLinkTap` callback + `isTelegramLink` helper
- [x] Step 2: FeedCardView — add `onPostLinkTap` parameter, pass to FormattedTextView
- [x] Step 3: FeedView — wire `onPostLinkTap` to open ChannelSheetView with parsed message ID

---

## Feed Stability Log (2026-03-06)

- [x] ChannelSheet: initial open now resolves the visible cell by exact `messageId` and scrolls to that cell instead of replacing the target with a fallback neighbor.
- [x] ChannelSheet: each rendered card now exposes scroll anchors for every represented Telegram `messageId`, so opening a post scrolls by the exact tapped ID rather than by a derived card position.
- [x] ChannelSheet/FeedView: removed the extra manual `scrollPosition` reassignment after `scrollTo`, which had been causing a second snap below the target message.
- [x] FeedView: scroll restoration now goes through one programmatic scroll pipeline; saved position is preserved on relaunch, and channel toggles keep the nearest surviving message instead of jumping to the bottom.
- [x] Feed FAB: the down button now uses the same explicit scroll request flow and returns to the newest loaded message.
- [x] Launch screen: added `LaunchScreen.storyboard` with a simple static title/subtitle composition for app startup.
- [x] Verification: `xcodebuild -project TFeed.xcodeproj -scheme TFeed -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build` succeeded on 2026-03-06.

---

## Simplify Scroll Position — Use Telegram Read State (2026-03-06)

### Goal

Remove local scroll position storage. Use Telegram's `lastReadInboxMessageId` as the single source of truth for where to resume reading. Each app start: show spinner, load 10 messages before first unread + all messages after, scroll to first unread.

### Flow

```
App Start → Spinner
  → Load channels (get lastReadInboxMessageId per channel)
  → Load latest messages per channel
  → Find first unread message across all channels
    (oldest message where messageId > lastReadInboxMessageId for its channel)
  → Keep 10 items before first unread + all items after
  → Scroll to first unread → Show feed

During use:
  → User scrolls and reads messages
  → Visible messages are marked as read (viewMessages sent to Telegram)
  → No local position storage

Next start:
  → Repeat from top (Telegram knows what's read)
```

### Steps

- [x] 1. Update FeedViewModel.load() — remove restoredPosition, find first unread from Telegram read state, prepareWindow with 10 items before
- [x] 2. Remove ScrollPositionStore usage from FeedView — no save, no restore, no debug banner
- [x] 3. Fix visibility tracking — removed ScrollViewReader wrapper from feedContent (likely cause of onScrollTargetVisibilityChange not firing)
- [x] 4. Fix initial scroll positioning — ScrollPosition(id:anchor:) constructor used before isContentReady gate
- [x] 5. Fix ChannelSheetView scroll — added backup scrollPosition.scrollTo() after 50ms delay
- [x] 6. Clean up — build verified, debug overlay removed, ScrollPositionStore left for potential future use
