.PHONY: build up down logs validate deploy

build:
	docker compose build

up:
	docker compose up -d --build jenkins

down:
	docker compose down

logs:
	docker compose logs -f jenkins

validate:
	docker compose run --rm monaco deploy --dry-run manifest.yaml

deploy:
	docker compose run --rm monaco deploy manifest.yaml
