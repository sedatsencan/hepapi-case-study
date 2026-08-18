// Runs entirely inside the cluster. Every stage executes in a disposable agent
// pod defined by the Kubernetes cloud in kubernetes/jenkins/casc.yaml, and the
// image is built without a Docker daemon.
pipeline {
    agent {
        kubernetes {
            inheritFrom 'build'
            defaultContainer 'tools'
        }
    }

    options {
        timeout(time: 20, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '10'))
    }

    environment {
        NAMESPACE  = 'taskmanager'
        RELEASE    = 'taskmanager'
        REGISTRY   = 'registry.registry.svc.cluster.local:5000'
        IMAGE_NAME = 'hepapi-case-study'
        // APP_VERSION and IMAGE_TAG are derived in the Version stage, because
        // they are read out of Chart.yaml rather than being hardcoded here.
    }

    stages {
        stage('Version') {
            steps {
                script {
                    // The application version comes from the chart, so the
                    // chart and the image it deploys can never disagree.
                    env.APP_VERSION = sh(
                        script: "sed -n 's/^appVersion: *\"\\(.*\\)\"/\\1/p' /workspace/charts/taskmanager/Chart.yaml",
                        returnStdout: true).trim()
                    def chartVersion = sh(
                        script: "sed -n 's/^version: *//p' /workspace/charts/taskmanager/Chart.yaml",
                        returnStdout: true).trim()

                    // Both must be semantic versions. A chart that claims a
                    // version it was not cut from is worse than an unversioned
                    // one, because it looks trustworthy.
                    def semver = /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?$/
                    if (!(env.APP_VERSION ==~ semver)) {
                        error("appVersion '${env.APP_VERSION}' is not a semantic version")
                    }
                    if (!(chartVersion ==~ semver)) {
                        error("chart version '${chartVersion}' is not a semantic version")
                    }

                    // The deployed tag carries the released version plus the
                    // build that produced it, so it is both traceable and
                    // unique. Uniqueness matters: with imagePullPolicy
                    // IfNotPresent a reused tag would silently keep old code.
                    env.IMAGE_TAG = "${env.APP_VERSION}-build.${env.BUILD_NUMBER}"
                    echo "chart ${chartVersion}, application ${env.APP_VERSION}, image tag ${env.IMAGE_TAG}"
                }
            }
        }

        stage('Checkout') {
            steps {
                // The working tree is mounted read-only, so it is copied into
                // the agent rather than built in place.
                sh '''
                    cp -r /workspace/. .
                    rm -rf .git .bin
                    echo "building $(ls -1 | wc -l) top-level entries"
                '''
            }
        }

        stage('Verify') {
            parallel {
                stage('Chart') {
                    steps {
                        sh '''
                            for values in values.yaml values-local.yaml; do
                              helm lint charts/taskmanager --values "charts/taskmanager/${values}"
                            done
                        '''
                    }
                }
                stage('Manifests') {
                    steps {
                        // Rendering with the real values proves the templates
                        // produce valid objects before anything is applied.
                        sh '''
                            helm template "${RELEASE}" charts/taskmanager \
                              --namespace "${NAMESPACE}" \
                              --values charts/taskmanager/values-local.yaml > /tmp/rendered.yaml
                            grep -q 'kind: Deployment' /tmp/rendered.yaml
                            echo "rendered $(grep -c '^kind:' /tmp/rendered.yaml) objects"
                        '''
                    }
                }
                stage('No leaked credential') {
                    steps {
                        // The database password is assembled by kubelet from
                        // $(VAR) references; it must never appear in output.
                        sh '''
                            rendered="$(helm template "${RELEASE}" charts/taskmanager \
                              --namespace "${NAMESPACE}" --values charts/taskmanager/values.yaml)"
                            echo "${rendered}" | grep -q 'mongodb://$(MONGODB_USERNAME):$(MONGODB_PASSWORD)@'
                            if echo "${rendered}" | grep -qE 'mongodb://[^$]+:[^$]+@'; then
                              echo "a literal credential was rendered"; exit 1
                            fi
                            echo "connection string is assembled at runtime"
                        '''
                    }
                }
            }
        }

        stage('Build image') {
            steps {
                container('kaniko') {
                    // No Docker daemon in the cluster, so kaniko builds from the
                    // filesystem and pushes straight to the in-cluster registry.
                    sh '''
                        /kaniko/executor \
                          --context "${WORKSPACE}" \
                          --dockerfile "${WORKSPACE}/Dockerfile" \
                          --destination "${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}" \
                          --destination "${REGISTRY}/${IMAGE_NAME}:${APP_VERSION}" \
                          --insecure --skip-tls-verify \
                          --single-snapshot
                    '''
                }
            }
        }

        stage('Deploy') {
            steps {
                // --atomic rolls back automatically if the new pods never become
                // ready, so a bad build cannot leave the namespace half-updated.
                sh '''
                    helm upgrade --install "${RELEASE}" charts/taskmanager \
                      --namespace "${NAMESPACE}" \
                      --values charts/taskmanager/values-local.yaml \
                      --set "image.repository=${REGISTRY}/${IMAGE_NAME}" \
                      --set "image.tag=${IMAGE_TAG}" \
                      --atomic --wait --timeout 10m
                '''
            }
        }

        stage('Verify deployment') {
            steps {
                sh '''
                    kubectl --namespace "${NAMESPACE}" rollout status \
                      "deployment/${RELEASE}" --timeout=300s
                    helm test "${RELEASE}" --namespace "${NAMESPACE}" --logs
                '''
            }
        }
    }

    post {
        success {
            echo "deployed ${IMAGE_NAME}:${IMAGE_TAG} (application ${APP_VERSION})"
        }
        failure {
            // Turns a red build into something readable without digging.
            sh '''
                kubectl --namespace "${NAMESPACE}" get pods -o wide || true
                kubectl --namespace "${NAMESPACE}" describe pods || true
                helm history "${RELEASE}" --namespace "${NAMESPACE}" || true
            '''
        }
    }
}
