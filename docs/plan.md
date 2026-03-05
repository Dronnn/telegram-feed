# TFeed — Plan

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
- [ ] `FormattedTextView` — bold, italic, links, code, spoilers
- [ ] `ReactionsBarView` — капсулы emoji + count, glass material
- [ ] Счётчик непрочитанных + FAB «вниз»
- [ ] Сохранение/восстановление scroll position

### Фаза 6: Канал и настройки
- [ ] `ChannelViewModel` + `ChannelSheetView` — single channel view
- [ ] `SettingsViewModel` + `SettingsView` — channel toggles, search
- [ ] «Clear Local Cache» + confirmation dialog
- [ ] «Log Out» + confirmation dialog + TDLib logout
- [ ] Persist selected channel IDs в SwiftData (`SelectedChannel` @Model)

### Фаза 7: Polish и GitHub
- [ ] Liquid Glass materials на карточках, toolbar, FAB
- [ ] Пустые состояния (нет каналов, нет сообщений)
- [ ] Обработка ошибок сети (no connection state)
- [ ] Light/dark mode тестирование
- [ ] README.md: описание, скриншоты, build instructions, лицензия
- [ ] `.gitignore` (credentials, build artifacts)
- [ ] Memory profiling (большие ленты, много медиа)
- [ ] Scroll position persistence across app kill

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

- [ ] Create Xcode project (pbxproj, workspace) with iOS 26 target, Swift 6, TDLibKit SPM
- [ ] Create TFeedApp.swift - SwiftUI app entry point with AppState environment
- [ ] Create RootView.swift - routing between auth states
- [ ] Create Core/AppState.swift - @Observable with AuthState enum
- [ ] Create Core/Constants.swift - API credentials placeholder (gitignored)
- [ ] Create Models/AuthStep.swift - auth step enum
- [ ] Create Services/TDLibService.swift - actor singleton wrapping TDLibKit
- [ ] Create Services/UpdateRouter.swift - @MainActor AsyncStream broadcast
- [ ] Create Views/Auth/AuthView.swift - placeholder
- [ ] Create Views/Feed/FeedView.swift - placeholder
- [ ] Create Resources/Assets.xcassets - accent color, app icon
- [ ] Create TFeed.entitlements - empty skeleton
- [ ] Update .gitignore - Xcode, credentials, macOS ignores

---

## Auth Hotfix Plan (2026-03-05)

- [ ] По запросу пользователя код auth-фикса откатан; следующему агенту нужно реализовать фиксы заново и перепроверить их.
- [ ] Следующему агенту (ПЕРВЫЙ ПРИОРИТЕТ): устранить ошибку "код не приходит в официальный Telegram-клиент и не приходит по SMS после ввода номера"; подтвердить end-to-end на реальном номере, что код реально доходит пользователю.
- [ ] Статус на 2026-03-05 (device check): пользователь подтвердил, что код все еще не приходит в официальный Telegram-клиент и не приходит по SMS.
- [ ] Следующему агенту: перепроверить, действительно ли Telegram сервер получает и обрабатывает `setAuthenticationPhoneNumber`/`resendAuthenticationCode` на живом номере (по логам и фактической доставке кода).
- [ ] Следующему агенту: проверить, не возвращается ли `authenticationCodeTypeFirebaseIos` и нужно ли отдельное поведение для него.
- [ ] Следующему агенту: подтвердить UX/тексты и оставить только нужные изменения.
