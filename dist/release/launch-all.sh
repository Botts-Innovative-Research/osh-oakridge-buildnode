if ! command -v docker >/dev/null 2>&1; then
    echo "Error: Docker is not installed. Please install Docker first."
    exit 1
fi

if ! command -v docker-compose >/dev/null 2>&1 && ! docker compose version >/dev/null 2>&1; then
    echo "Error: Docker Compose is not installed. Please install Docker Compose."
    exit 1
fi

DOCKER_COMPOSE_CMD="docker-compose"
if command -v docker compose >/dev/null 2>&1; then
    DOCKER_COMPOSE_CMD="docker compose"
fi

echo "Starting application using Docker Compose..."
cd "$PROJECT_DIR"
$DOCKER_COMPOSE_CMD up -d

echo "Application started successfully."