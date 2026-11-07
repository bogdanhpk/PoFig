# Публикация PoFig

В репозитории хранится код; бинарные пакеты публикуются в GitHub Releases. Папки `build/`, `target/`, `.tools/`, настройки пользователей и ключи подписи в коммит не включаются.

1. Обновите версию в `Cargo.toml`, `macos/Info.plist` и `windows/PoFig/PoFig.csproj`, затем обновите `Cargo.lock` и ссылки на скачивание в README.
2. Выполните проверки и сборку. Для macOS используйте `bash scripts/build-macos.sh --universal`, для Windows — `scripts/build-windows.ps1` с нужным `-Runtime`.
3. Отправьте исходники в GitHub и дождитесь успешных проверок Actions. Сборка Windows не заменяет ручную проверку её интерфейса.
4. Подготовьте контрольные суммы ZIP и заметки о версии. Для локально подписанного Mac-пакета явно укажите отсутствие Developer ID и нотариализации; сохраните инструкцию первого открытия в архиве.
5. Создайте тег версии и отправьте его в репозиторий:

```sh
git tag -a v0.1.1 -m "PoFig v0.1.1"
git push origin v0.1.1
```

6. Создайте выпуск на странице Releases или через GitHub CLI, загрузив архивы macOS, Windows x64, Windows ARM64 и `SHA256SUMS.txt`. Для предварительной версии отметьте **Pre-release**.

```sh
gh release create v0.1.1 \
  build/PoFig-macOS.zip \
  build/PoFig-win-x64.zip \
  build/PoFig-win-arm64.zip \
  build/SHA256SUMS.txt \
  --repo bogdanhpk/PoFig \
  --verify-tag \
  --title "PoFig v0.1.1" \
  --notes-file docs/releases/v0.1.1.md \
  --prerelease
```

Указывайте реальные результаты проверки для каждой платформы. Публикуйте Mac-пакет как нотариализованный только после принятия Apple, прикрепления билета и успешной проверки Gatekeeper.
