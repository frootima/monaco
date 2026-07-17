pipeline {
  agent any

  options {
    disableConcurrentBuilds()
    skipDefaultCheckout(true)
    timestamps()
  }

  environment {
    DT_ENV_URL = 'https://ann36102.live.dynatrace.com'
    MONACO_IMAGE = 'monaco-poc:local'
  }

  stages {
    stage('Checkout') {
      steps {
        checkout scm
      }
    }

    stage('Build Monaco image') {
      steps {
        sh 'docker build --pull -f Dockerfile.monaco -t "$MONACO_IMAGE" .'
      }
    }

    stage('Validate') {
      steps {
        withCredentials([string(credentialsId: 'dynatrace-api-token', variable: 'DT_API_TOKEN')]) {
          sh '''
            set -eu
            if [ "$DT_API_TOKEN" = "REPLACE_WITH_DYNATRACE_API_TOKEN" ]; then
              echo "Configure DYNATRACE_API_TOKEN in .env and recreate Jenkins." >&2
              exit 2
            fi

            docker run --rm \
              -e DT_ENV_URL \
              -e DT_API_TOKEN \
              -v "$WORKSPACE:/workspace" \
              -w /workspace \
              "$MONACO_IMAGE" deploy --dry-run manifest.yaml
          '''
        }
      }
    }

    stage('Deploy to Dynatrace') {
      steps {
        withCredentials([string(credentialsId: 'dynatrace-api-token', variable: 'DT_API_TOKEN')]) {
          sh '''
            set -eu
            docker run --rm \
              -e DT_ENV_URL \
              -e DT_API_TOKEN \
              -v "$WORKSPACE:/workspace" \
              -w /workspace \
              "$MONACO_IMAGE" deploy manifest.yaml
          '''
        }
      }
    }
  }

  post {
    success {
      echo 'Dynatrace dashboard and alert configuration deployed successfully.'
    }
    failure {
      echo 'Deployment failed. Dynatrace was not updated by the failed stage.'
    }
  }
}
