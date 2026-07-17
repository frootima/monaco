pipeline {
  agent any

  options {
    disableConcurrentBuilds()
    skipDefaultCheckout(true)
  }

  environment {
    DT_ENV_URL = 'https://ann36102.apps.dynatrace.com'
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
        withCredentials([
          string(credentialsId: 'dynatrace-api-token', variable: 'DT_API_TOKEN'),
          string(credentialsId: 'dynatrace-platform-token', variable: 'DT_PLATFORM_TOKEN')
        ]) {
          sh '''
            set -eu
            if [ "$DT_API_TOKEN" = "REPLACE_WITH_DYNATRACE_API_TOKEN" ]; then
              echo "Configure DYNATRACE_API_TOKEN in .env and recreate Jenkins." >&2
              exit 2
            fi
            if [ "$DT_PLATFORM_TOKEN" = "REPLACE_WITH_DYNATRACE_PLATFORM_TOKEN" ]; then
              echo "Configure DYNATRACE_PLATFORM_TOKEN in .env and recreate Jenkins." >&2
              exit 2
            fi

            docker run --rm \
              -e DT_ENV_URL \
              -e DT_API_TOKEN \
              -e DT_PLATFORM_TOKEN \
              --volumes-from monaco-jenkins \
              -w "$WORKSPACE" \
              "$MONACO_IMAGE" deploy --dry-run manifest.yaml
          '''
        }
      }
    }

    stage('Deploy to Dynatrace') {
      steps {
        withCredentials([
          string(credentialsId: 'dynatrace-api-token', variable: 'DT_API_TOKEN'),
          string(credentialsId: 'dynatrace-platform-token', variable: 'DT_PLATFORM_TOKEN')
        ]) {
          sh '''
            set -eu
            docker run --rm \
              -e DT_ENV_URL \
              -e DT_API_TOKEN \
              -e DT_PLATFORM_TOKEN \
              --volumes-from monaco-jenkins \
              -w "$WORKSPACE" \
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
