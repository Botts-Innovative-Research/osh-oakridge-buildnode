DOCKER_COMPOSE_CMD="docker-compose"
if command -v docker compose >/dev/null 2>&1; then
    DOCKER_COMPOSE_CMD="docker compose"
fi

$DOCKER_COMPOSE_CMD -f docker-compose-arm.yml down
echo "Application stopped."