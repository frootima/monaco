.PHONY: build up down logs render validate deploy

build:
	docker compose build

up:
	docker compose up -d --build jenkins

down:
	docker compose down

logs:
	docker compose logs -f jenkins

render:
	docker compose run --rm --entrypoint sh monaco scripts/render-dashboard.sh

validate: render
	docker compose run --rm monaco deploy --dry-run manifest.yaml

deploy: render
	docker compose run --rm monaco deploy manifest.yaml
