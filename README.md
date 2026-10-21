# TripFund

Контракт для сбора на поездку команды. Взносы, выплата организатору и возвраты работают с одним токеном ERC-20. В проекте есть обычная версия и версия с обновлением через Transparent Proxy.

## Версии и установка

- Solidity 0.8.24, EVM Cancun.
- Foundry 1.7.1 (`forge`, `cast`, `anvil`).
- Node.js 22 или новее, npm.
- OpenZeppelin Contracts 5.4.0.
- OpenZeppelin Upgrades Core 1.44.2.

Установите [Foundry](https://getfoundry.sh/introduction/installation/), выберите версию 1.7.1 и установите зависимости проекта.

```sh
foundryup --install v1.7.1
npm ci
forge build
forge test
```

Версии зависимостей записаны в `package-lock.json`. Foundry загружает компилятор автоматически. Тесты используют стандартные cheatcodes Foundry через интерфейс в `test/TestBase.sol`.

Для запуска всех проверок выполните `npm run check`.

```sh
npm run check
```

## Архитектура

| Файл | Назначение |
| --- | --- |
| `src/TripFundCore.sol` | Общая логика взносов, выплат и возвратов |
| `src/TripFund.sol` | Основной контракт, задающий параметры в конструкторе |
| `src/TripFundV1.sol` | Инициализируемая реализация для Transparent Proxy |
| `src/TripFundV2.sol` | Наследует V1, добавляет `contributeFor`, не меняет storage |
| `src/MockToken.sol` | Локальный OpenZeppelin ERC20 без комиссии и rebasing |
| `script/DeployLocal.s.sol` | Развёртывание токена и прокси V1 с инициализацией |
| `script/UpgradeToV2.s.sol` | Обновление того же прокси владельцем ProxyAdmin до дедлайна |

`contribute` вызывает `_contribute`, который записывает взнос в `contributions`, увеличивает `totalRaised` и забирает токены через `safeTransferFrom`. После перевода создаётся событие `Contribution`. В V2 метод `contributeFor` использует ту же логику и записывает взнос указанному получателю. Токены списываются у `msg.sender`.

`refund` читает вклад вызывающего, обнуляет его и выполняет `safeTransfer`. `withdraw` проверяет организатора и исход, отмечает `withdrawn` и переводит ровно `totalRaised`. Все операции защищены от повторного входа. Ошибка токена откатывает учёт, флаг выплаты, события и изменения токенных балансов в транзакции.

`totalRaised` хранит историческую сумму принятых взносов и не уменьшается. Успех определяется только по ней. Прямые переводы не дают права на возврат и остаются на контракте после расчётов. До `deadline` доступны взносы, начиная с `deadline` доступны выплаты. Функций изменения параметров нет.

## Основной контракт

Конструктор `TripFund(address token, address organizer, uint256 goal, uint256 deadline)` принимает адреса токена и организатора, цель сбора и срок. При создании проверяются следующие условия.

- ненулевые адреса токена и организатора;
- `goal > 0` в минимальных единицах ERC-20;
- `deadline > block.timestamp`, время Unix в секундах.

## Локальный запуск

Запустите локальную сеть в отдельном терминале.

```sh
anvil
```

В терминале проекта укажите приватный ключ первого аккаунта из вывода Anvil и запустите скрипт развёртывания.

```sh
export RPC_URL=http://127.0.0.1:8545
read -r -s PRIVATE_KEY
export PRIVATE_KEY
forge script script/DeployLocal.s.sol:DeployLocal --rpc-url "$RPC_URL" --broadcast
```

Скрипт возвращает `token`, `fund` и `proxyAdmin`. `fund` — адрес прокси; организатор и владелец ProxyAdmin — аккаунт отправителя. Ему начислены 1000 TRIP, цель по умолчанию — 100 TRIP, срок — через 7 дней. `MockToken.mint` открыт для локальных сценариев.

Подставьте адреса из вывода скрипта. В `BENEFICIARY` укажите аккаунт, за который хотите сделать взнос после обновления.

```sh
export TOKEN=0x...
export PROXY=0x...
export BENEFICIARY=0x...
cast send "$TOKEN" 'approve(address,uint256)' "$PROXY" 20000000000000000000 --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY"
cast send "$PROXY" 'contribute(uint256)' 20000000000000000000 --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY"
cast call "$PROXY" 'totalRaised()(uint256)' --rpc-url "$RPC_URL"
```

У токена 18 знаков после запятой; пример вносит 20 TRIP. Для основного контракта в примере замените `PROXY` адресом развёрнутого `TripFund`. `approve` всегда вызывается у токена, а spender — адрес фонда, через который делается взнос.

## Проверка хранилища и обновление

```sh
npm run validate:upgrade
forge script script/UpgradeToV2.s.sol:UpgradeToV2 --rpc-url "$RPC_URL" --broadcast
cast send "$TOKEN" 'approve(address,uint256)' "$PROXY" 10000000000000000000 --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY"
cast send "$PROXY" 'contributeFor(address,uint256)' "$BENEFICIARY" 10000000000000000000 --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY"
```

OpenZeppelin Upgrades проверяет V1 и сравнивает хранилище V2 с V1. Исходная версия задаётся через `--reference` и `--requireReference`. Флаг `--unsafeAllow constructor` разрешает конструктор V1 с вызовом `_disableInitializers()`, который блокирует прямую инициализацию обеих реализаций. Проверка совместимости хранилища остаётся включённой.

`forge build --force` в команде проверки удаляет устаревший build-info перед компиляцией, чтобы валидатор не сравнивал несколько копий одной реализации. V2 наследует хранилище V1 без новых полей и использует существующую инициализацию. Прокси инициализируется в конструкторе `TransparentUpgradeableProxy`, повторная инициализация запрещена.

Прокси OpenZeppelin 5.x сам создаёт `ProxyAdmin`; второй аргумент его конструктора — владелец этого ProxyAdmin. Обновление выполняется вызовом `ProxyAdmin.upgradeAndCall`, доступным только владельцу. Адрес фонда, разрешения ERC-20, параметры и накопленный учёт сохраняются. Организатор и администратор — независимые роли, даже если локальный пример назначает им один аккаунт.

Чтобы приблизить локальное время к дедлайну, используйте `cast rpc evm_setNextBlockTimestamp <deadline> --rpc-url "$RPC_URL"` и `cast rpc evm_mine --rpc-url "$RPC_URL"`. После провала получатель подаренного взноса вызывает `refund()`, после успеха организатор вызывает `withdraw()`.

## Покрытие требований

| Пункты | Проверки |
| --- | --- |
| 1 | Валидные параметры, нулевые адреса/цель, текущий и прошедший дедлайн |
| 2–3, 6 | Два участника, повторные взносы, нулевая сумма, баланс и allowance; состояние после отката |
| 4, 7–8 | Взнос за секунду до срока и отказ ровно в срок; ранние выплаты, ровно цель и превышение; независимые возвраты, чужие и повторные выплаты |
| 5 | События, false-return ERC-20, повторная попытка после отката; наблюдение учёта внутри токенного вызова и защита от reentrancy |
| 9 | Прямые переводы не меняют исход и остаются после вывода и всех возвратов |
| 10 | Transparent Proxy 5.x, атомарная инициализация, блокировка реализаций и повторной инициализации, права ProxyAdmin |
| 11 | `contributeFor`, нулевой получатель, сроки, сумма, баланс и allowance плательщика, событие и право возврата получателя |
| 12 | Взносы в V1, обновление до срока с сохранением адреса и данных, обычный взнос и взнос за друга в V2, возвраты и проверка хранилища через OpenZeppelin |

Общий набор поведенческих тестов выполняется для основного контракта, V1 и V2 через прокси. Дополнительно выполняются тесты обновления, защиты от повторного входа и fuzz-проверки с 256 наборами входных данных на версию. GitHub Actions запускает `npm run check`.

## Материалы

- [OpenZeppelin ERC20 и SafeERC20](https://docs.openzeppelin.com/contracts/5.x/api/token/erc20)
- [TransparentUpgradeableProxy и ProxyAdmin](https://docs.openzeppelin.com/contracts/5.x/api/proxy)
- [OpenZeppelin Upgrades Core](https://docs.openzeppelin.com/upgrades-plugins/api-core)
