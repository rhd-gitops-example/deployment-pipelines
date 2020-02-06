# A Step by Step Guide to Deployment Example

Tekton deployments from GitHub

## Requirements

* Tekton Pipeline v0.10.1
* Tekton Triggers v0.2.1
* Set the following environment varialbes
    * USER=\<OS user \>  (It should be automatically set by OS.)
    * QUAY_USER=\<Ouay.io user\>
    * GITHUB_USER=\<GitHub user\>
    * DEPLOYMENT_PATH=deploy


## Create demo Git repos

Login to Your GitHub account.  Create your demo git reposs `taxi` and `taxi-stage-config`.  Import from the following repos, respectively.   
   * https://github.com/bigkevmcd/taxi
   * https://github.com/bigkevmcd/taxi-stage-config

 
 ## Download your gihub access token
 
 Go to https://github.com/settings/tokens and generate an access token.   Download and save to `github-token.txt`.

 ![Screenshot](github-token.png)

## Create Projects/Namespaces

```shell
oc new-project ${USER}-dev-environment
oc new-project ${USER}-stage-environment
oc new-project ${USER}-cicd-environment
```

**_NOTE:_**  Continue this setup in `cicd-envnironment-${USER}` project.


## Quay Credentials to push built image to Quay.io registry

 * Create `taxi` Quay repos.   Login to your Quay.io account and create a repository `taxi`

  ![Screenshot](create-taxi-in-quay.png)

 * Login to your Quay.io account that you can generate read/write credentials for.  In user's name pulldown menu, goto Account Settings -> Robot Account (button on the left).   Create a robot account for yourself.  Click your robot account link.

 ![Screenshot](quay-create-robot-account.png)

 * Select `Edit Repository Permissions` menu item

  ![Screenshot](edit-token-permission.png)

* Grant `write` permission to repository `taxi`

 ![Screenshot](grant-write-permission.png)

 * Download Kubernates Pull Secret (\<Quay.io user\>-robot-secret.yml)

 ![Screenshot](quay-download-secret.png)

 * Create Kubernates secret from downloaded pull secret yaml

 **_NOTE:_**  Replace \<path\to\> with path to yaml file. 
```shell
oc apply -f <path/to>/${QUAY_USER}-robot-secret.yml
  ```
* Download Docker Configuration file to `<Quay user>-robot-auth.json`

   ![Screenshot](quay-download-docker-config.png)

* Create `regcred` secret from Docker Configuration file

**_NOTE:_**  Make sure `QUAY_USER` envrionment variable is set.
**_NOTE:_**  Modify path to downloaded file accordingly.

```shell
oc create secret generic regcred --from-file=.dockerconfigjson="$HOME/Downloads/${QUAY_USER}-robot-auth.json" --type=kubernetes.io/dockerconfigjson
```

 You can check the created secrets. 
 
 ```shell
 oc get secret
 ```

 ## Setup Service Account

* Create Service Account (**replace \<user\> with your userid**)

**_NOTE:_**  Make sure `QUAY_USER` envrionment variable is set.


```shell
cat <<EOF | oc apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: demo-sa
secrets:
- name: ${QUAY_USER}-robot-pull-secret
- name: regcred
EOF
```
* Create Role

 ```shell
cat <<EOF | oc apply -f -
kind: Role
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: tekton-triggers-openshift-demo
rules:
- apiGroups: ["tekton.dev"]
   resources: ["eventlisteners", "triggerbindings", "triggertemplates", "tasks", "taskruns"]
   verbs: ["get"]
- apiGroups: ["tekton.dev"]
   resources: ["pipelineruns", "pipelineresources", "taskruns"]
   verbs: ["create"]
EOF
```
 * Create Role Binding

 ```shell
 cat <<EOF | oc apply -f -
 apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
   name: tekton-triggers-openshift-binding
subjects:
- kind: ServiceAccount
   name: demo-sa
roleRef:
   apiGroup: rbac.authorization.k8s.io
   kind: Role
   name: tekton-triggers-openshift-demo
 EOF
 ```
 * Configure Service Account admin policy 
 ```shell
oc adm policy add-scc-to-user privileged -z demo-sa
oc adm policy add-role-to-user edit -z demo-sa
```
* Create Role Bindings for Service Accounts in `dev` and `stage` projects


```shell
oc create rolebinding demo-sa-admin-dev --clusterrole=admin --serviceaccount=${USER}-cicd-environment:demo-sa --namespace=${USER}-dev-environment
oc create rolebinding demo-sa-admin-stage --clusterrole=admin --serviceaccount=${USER}-cicd-environment:demo-sa --namespace=${USER}-stage-environment
```
## Create Tasks

Create buildah task yaml file with the following content.  Apply yaml file.   `oc appyl -f <yaml file>`

```shell
apiVersion: tekton.dev/v1alpha1
kind: Task
metadata:
  name: buildah-task
spec:
  inputs:
    params:
    - name: BUILDER_IMAGE
      description: The location of the buildah builder image.
      default: quay.io/buildah/stable:v1.11.3
      type: string
    - name: DOCKERFILE
      description: Path to the Dockerfile to build.
      default: ./Dockerfile
      type: string
    - name: TLSVERIFY
      description: Verify the TLS on the registry endpoint (for push/pull to a non-TLS registry)
      default: "true"
      type: string
    resources:
    - name: source
      type: git
  outputs:
    resources:
    - name: image
      type: image
  steps:
  - name: build
    image: $(inputs.params.BUILDER_IMAGE)
    workingDir: /workspace/source
    command: ['buildah', 'bud', '--tls-verify=$(inputs.params.TLSVERIFY)', '--layers', '-f', '$(inputs.params.DOCKERFILE)', '-t', '$(outputs.resources.image.url)', '.']
    volumeMounts:
    - name: varlibcontainers
      mountPath: /var/lib/containers
    securityContext:
      privileged: true
  - name: push
    image: $(inputs.params.BUILDER_IMAGE)
    workingDir: /workspace/source
    command: ['buildah', 'push', '--tls-verify=$(inputs.params.TLSVERIFY)', '$(outputs.resources.image.url)', 'docker://$(outputs.resources.image.url)']
    volumeMounts:
    - name: varlibcontainers
      mountPath: /var/lib/containers
    securityContext:
      privileged: true
  volumes:
  - name: varlibcontainers
    emptyDir: {}
```

Create github status task

* Save the following content to `temp.yaml`

```shell
apiVersion: tekton.dev/v1alpha1
kind: Task
metadata:
  name: create-github-status-task
spec:
  inputs:
    params:
    - name: REPO
      description: The repo to publish the status update for e.g. tektoncd/triggers
      type: string
    - name: COMMIT_SHA
      description: The specific commit to report a status for.
      type: string
    - name: STATE
      description: The state to report error, failure, pending, or success.
      type: string
    - name: TARGET_URL
      type: string
      default: ""
      description: The target URL to associate with this status.
    - name: DESCRIPTION
      type: string
      description: A short description of the status.
    - name: CONTEXT
      type: string
      description: A string label to differentiate this status from the status of other systems.
  steps:
  - name: start-status
    image: quay.io/kmcdermo/github-tool:latest
    workingDir: /workspace/source
    env:
    - name: GITHUB_TOKEN
      valueFrom:
        secretKeyRef:
          name: $GITHUB_USER-github-auth
          key: token
    command: ["github-tool"]
    args:
      - "create-status"
      - "--repo"
      - "$(inputs.params.REPO)"
      - "--sha"
      - "$(inputs.params.COMMIT_SHA)"
      - "--state"
      - "$(inputs.params.STATE)"
      - "--target-url"
      - "$(inputs.params.TARGET_URL)"
      - "--description"
      - "$(inputs.params.DESCRIPTION)"
      - "--context"
      - "$(inputs.params.CONTEXT)"
```      
* Run the following command to apply `temp.yaml` with `sed` command to replace string value

**_NOTE:_**  Make sure `GIBHUB_USER` envrionment variable is set.

```shell
cat temp.yaml | sed s"/\$GITHUB_USER/$GITHUB_USER/" | oc apply -f -
```

Create `deploy-from-source-task`

Create task yaml file with the following content.  Apply yaml file.   `oc appyl -f <yaml file>`

```shell
apiVersion: tekton.dev/v1alpha1
kind: Task
metadata:
  name: deploy-from-source-task
spec:
  inputs:
    resources:
      - name: source
        type: git
    params:
      - name: PATHTODEPLOYMENT
        type: string
        description: Path to the manifest to apply
        default: deploy
      - name: NAMESPACE
        type: string
        description: Namespace to deploy into
      - name: DRYRUN
        type: string
        description: If true run a server-side dryrun.
        default: "false"
  steps:
    - name: run-kubectl
      image: quay.io/kmcdermo/k8s-kubectl:latest
      workingDir: /workspace/source
      command: ["kubectl"]
      args:
        - "apply"
        - "--dry-run=$(inputs.params.DRYRUN)"
        - "-n"
        - "$(inputs.params.NAMESPACE)"
        - "-k"
        - "$(inputs.params.PATHTODEPLOYMENT)"
```

Create deploy-using-kubectl-task

Create task yaml file with the following content.  Apply yaml file.   `oc appyl -f <yaml file>`

```shell
apiVersion: tekton.dev/v1alpha1
kind: Task
metadata:
  name: deploy-using-kubectl-task
spec:
  inputs:
    resources:
      - name: source
        type: git
      - name: image
        type: image
    params:
      - name: PATHTODEPLOYMENT
        type: string
        description: Path to the manifest to apply
        default: deploy
      - name: NAMESPACE
        type: string
        description: Namespace to deploy into
      - name: DRYRUN
        type: string
        description: If true run a server-side dryrun.
        default: "false"
      - name: YAMLPATHTOIMAGE
        type: string
        description:
          The path to the image to replace in the yaml manifest (arg to yq)
  steps:
    - name: replace-image
      image: mikefarah/yq
      workingDir: /workspace/source
      command: ["yq"]
      args:
        - "w"
        - "-i"
        - "$(inputs.params.PATHTODEPLOYMENT)/deployment.yaml"
        - "$(inputs.params.YAMLPATHTOIMAGE)"
        - "$(inputs.resources.image.url)"
    - name: run-kubectl
      image: quay.io/kmcdermo/k8s-kubectl:latest
      workingDir: /workspace/source
      command: ["kubectl"]
      args:
        - "apply"
        - "--dry-run=$(inputs.params.DRYRUN)"        
        - "-n"
        - "$(inputs.params.NAMESPACE)"
        - "-k"
        - "$(inputs.params.PATHTODEPLOYMENT)"
```

## Create template and bindings

Create `dev-cd-deploy-from-master-binding`

Create yaml file with the following content.  Apply yaml file.   `oc appyl -f <yaml file>`


```shell
apiVersion: tekton.dev/v1alpha1
kind: TriggerBinding
metadata:
  name: dev-cd-deploy-from-master-binding
spec:
  params:
  - name: gitref
    value: $(body.head_commit.id)
  - name: gitrepositoryurl
    value: $(body.repository.clone_url)
```

Create `dev-cd-deploy-from-master-template` 

* Create `temp.yaml` with the following content  

```shell
apiVersion: tekton.dev/v1alpha1
kind: TriggerTemplate
metadata:
  name: dev-cd-deploy-from-master-template
spec:
  params:
  - name: gitref
    description: The git revision
    default: master
  - name: gitrepositoryurl
    description: The git repository url
  resourcetemplates:
  - apiVersion: tekton.dev/v1alpha1
    kind: PipelineRun
    metadata:
      name: dev-cd-pipeline-run-$(uid)
    spec:
      serviceAccountName: demo-sa
      pipelineRef:
        name: dev-cd-pipeline
      resources:
        - name: source-repo
          resourceSpec:
            type: git
            params:
            - name: revision
              value: $(params.gitref)
            - name: url
              value: $(params.gitrepositoryurl)
        - name: runtime-image
          resourceSpec:
            type: image
            params:
              - name: url
                value: quay.io/$QUAY_USER/taxi:$(params.gitref)
```
* Run the following command to apply `temp.yaml` with `sed` command to replace string

**_NOTE:_**  Make sure `QUAY_USER` envrionment variable is set.
```shell
cat temp.yaml  | sed s"/\$QUAY_USER/$QUAY_USER/" | oc apply -f -
```

Create `dev-ci-build-from-pr-binding`

Create yaml file with the following content.  Apply yaml file.   `oc appyl -f <yaml file>`


```shell
apiVersion: tekton.dev/v1alpha1
kind: TriggerBinding
metadata:
  name: dev-ci-build-from-pr-binding
spec:
  params:
  - name: gitref
    value: $(body.pull_request.head.ref)
  - name: gitsha
    value: $(body.pull_request.head.sha)
  - name: gitrepositoryurl
    value: $(body.repository.clone_url)
  - name: fullname
    value: $(body.repository.full_name)
```
Create `dev-ci-build-from-pr-template`

* Create `temp.yaml` with the following content.

```shell
apiVersion: tekton.dev/v1alpha1
kind: TriggerTemplate
metadata:
  name: dev-ci-build-from-pr-template
spec:
  params:
  - name: gitref
    description: The git branch for this PR
  - name: gitsha
    description: the specific commit SHA.
  - name: gitrepositoryurl
    description: The git repository url
  - name: fullname
    description: The GitHub repository for this PullRequest.
  resourcetemplates:
  - apiVersion: tekton.dev/v1alpha1
    kind: PipelineRun
    metadata:
      name: dev-ci-pipeline-run-$(uid)
    spec:
      serviceAccountName: demo-sa
      pipelineRef:
        name: dev-ci-pipeline
      params:
      - name: REPO
        value: $(params.fullname)
      - name: COMMIT_SHA
        value: $(params.gitsha)
      resources:
        - name: source-repo
          resourceSpec:
            type: git
            params:
            - name: revision
              value: $(params.gitref)
            - name: url
              value: $(params.gitrepositoryurl)
        - name: runtime-image
          resourceSpec:
            type: image
            params:
              - name: url
                value: quay.io/$QUAY_USER/taxi:$(params.gitref)-$(params.gitsha)
```
* Run the following command to apply `temp.yaml` and `sed` command to replace string

**_NOTE:_**  Make sure `QUAY_USER` envrionment variable is set.

```shell
cat temp.yaml  | sed s"/\$QUAY_USER/$QUAY_USER/" | oc apply -f -
```
Create `stage-cd-deploy-from-push-binding`

Create yaml file with the following content.  Apply yaml file.   `oc appyl -f <yaml file>`

```shell
apiVersion: tekton.dev/v1alpha1
kind: TriggerBinding
metadata:
  name: stage-cd-deploy-from-push-binding
spec:
  params:
  - name: gitref
    value: $(body.ref)
  - name: gitsha
    value: $(body.commits.0.id)
  - name: gitrepositoryurl
    value: $(body.repository.clone_url)
```

Create `stage-cd-deploy-from-push-template`

Create yaml file with the following content.  Apply yaml file.   `oc appyl -f <yaml file>`

```shell
apiVersion: tekton.dev/v1alpha1
kind: TriggerTemplate
metadata:
  name: stage-cd-deploy-from-push-template
spec:
  params:
  - name: gitref
    description: The git revision
    default: master
  - name: gitrepositoryurl
    description: The git repository url
  resourcetemplates:
  - apiVersion: tekton.dev/v1alpha1
    kind: PipelineRun
    metadata:
      name: stage-cd-pipeline-run-$(uid)
    spec:
      serviceAccountName: demo-sa
      pipelineRef:
        name: stage-cd-pipeline
      resources:
        - name: source-repo
          resourceSpec:
            type: git
            params:
            - name: revision
              value: $(params.gitref)
            - name: url
              value: $(params.gitrepositoryurl)
```

Create `stage-ci-dryrun-from-pr-binding`

Create yaml file with the following content.  Apply yaml file.   `oc appyl -f <yaml file>`

```shell
apiVersion: tekton.dev/v1alpha1
kind: TriggerBinding
metadata:
  name: stage-ci-dryrun-from-pr-binding
spec:
  params:
  - name: gitref
    value: $(body.pull_request.head.ref)
  - name: gitrepositoryurl
    value: $(body.repository.clone_url)
```
Create `stage-ci-dryrun-from-pr-template`

Create yaml file with the following content.  Apply yaml file.   `oc appyl -f <yaml file>`


```shell
apiVersion: tekton.dev/v1alpha1
kind: TriggerTemplate
metadata:
  name: stage-ci-dryrun-from-pr-template
spec:
  params:
  - name: gitref
    description: The git revision
    default: master
  - name: gitrepositoryurl
    description: The git repository url
  resourcetemplates:
  - apiVersion: tekton.dev/v1alpha1
    kind: PipelineRun
    metadata:
      name: stage-ci-pipeline-run-$(uid)
    spec:
      serviceAccountName: demo-sa
      pipelineRef:
        name: stage-ci-pipeline
      resources:
        - name: source-repo
          resourceSpec:
            type: git
            params:
            - name: revision
              value: $(params.gitref)
            - name: url
              value: $(params.gitrepositoryurl)
```

## Create ci pipelines

Create `dev-ci-pipeline`
Create yaml file with the following content.  Apply yaml file.   `oc appyl -f <yaml file>`

```shell
apiVersion: tekton.dev/v1alpha1
kind: Pipeline
metadata:
  name: dev-ci-pipeline
spec:
  resources:
    - name: source-repo
      type: git
    - name: runtime-image
      type: image
  params:
    - name: REPO
      type: string
    - name: COMMIT_SHA
      type: string
  tasks:
    - name: create-pending-status
      taskRef:
        name: create-github-status-task
      params:
      - name: REPO
        value: $(params.REPO)
      - name: COMMIT_SHA
        value: $(params.COMMIT_SHA)
      - name: STATE
        value: "pending"
      - name: DESCRIPTION
        value: "Starting dev-ci-pipeline"
      - name: CONTEXT
        value: "dev-ci-pipeline"
    - name: build-image
      taskRef:
        name: buildah-task
      runAfter:
        - create-pending-status
      resources:
        inputs:
          - name: source
            resource: source-repo
        outputs:
          - name: image
            resource: runtime-image
    - name: create-success-status
      taskRef:
        name: create-github-status-task
      runAfter:
        - build-image
      params:
      - name: REPO
        value: $(params.REPO)
      - name: COMMIT_SHA
        value: $(params.COMMIT_SHA)
      - name: STATE
        value: "success"
      - name: DESCRIPTION
        value: "Completed dev-ci-pipeline"
      - name: CONTEXT
        value: "dev-ci-pipeline"
```

## Create stage CI Pipeline

```shell
cat <<EOF | oc apply -f -
apiVersion: tekton.dev/v1alpha1
kind: Pipeline
metadata:
  name: stage-ci-pipeline
spec:
  resources:
    - name: source-repo
      type: git
  tasks:
    - name: apply-source
      taskRef:
        name: deploy-from-source-task
      resources:
        inputs:
          - name: source
            resource: source-repo
      params:
      - name: NAMESPACE
        value: ${USER}-stage-environment
      - name: DRYRUN
        value: "true"
EOF
```
Create `dev-cd-pipeline`

```shell
cat <<EOF | oc apply -f -
apiVersion: tekton.dev/v1alpha1
kind: Pipeline
metadata:
  name: dev-cd-pipeline
spec:
  resources:
    - name: source-repo
      type: git
    - name: runtime-image
      type: image
  tasks:
    - name: build-image
      taskRef:
        name: buildah-task
      resources:
        inputs:
          - name: source
            resource: source-repo
        outputs:
          - name: image
            resource: runtime-image
    - name: deploy-image
      runAfter:
        - build-image
      taskRef:
        name: deploy-using-kubectl-task
      resources:
        inputs:
          - name: source
            resource: source-repo
          - name: image
            resource: runtime-image
      params:
      - name: PATHTODEPLOYMENT
        value: ${DEPLOYMENT_PATH}
      - name: YAMLPATHTOIMAGE
        value: "spec.template.spec.containers[0].image"
      - name: NAMESPACE
        value: ${USER}-dev-environment
EOF
```

Create `stage-cd-pipeline`


```shel
cat <<EOF | oc apply -f -
apiVersion: tekton.dev/v1alpha1
kind: Pipeline
metadata:
  name: stage-cd-pipeline
spec:
  resources:
    - name: source-repo
      type: git
  tasks:
    - name: apply-source
      taskRef:
        name: deploy-from-source-task
      resources:
        inputs:
          - name: source
            resource: source-repo
      params:
      - name: NAMESPACE
        value: ${USER}-stage-environment
EOF
```
## Create EventListener
Create `cicd-event-listener`

* Save the following content to `temp.yaml`


```shell
apiVersion: tekton.dev/v1alpha1
kind: EventListener
metadata:
  name: cicd-event-listener
spec:
  serviceAccountName: demo-sa
  triggers:
    - name: dev-ci-build-from-pr
      interceptors:
        - cel:
            filter: (header.match("X-GitHub-Event", "pull_request") && body.action == "opened" || body.action == "synchronize") && body.pull_request.head.repo.full_name == "$GITHUB_USER/taxi"
      bindings:
        - name: dev-ci-build-from-pr-binding
      template:
        name: dev-ci-build-from-pr-template
    - name: dev-cd-deploy-from-master
      interceptors:
        - cel:
            filter: (header.match("X-GitHub-Event", "push") && body.repository.full_name == "$GITHUB_USER/taxi") && body.ref.startsWith("refs/heads/master")
      bindings:
        - name: dev-cd-deploy-from-master-binding
      template:
        name: dev-cd-deploy-from-master-template
    - name: stage-ci-dryrun-from-pr
      interceptors:
        - cel:
            filter: (header.match("X-GitHub-Event", "pull_request") && body.action == "opened" || body.action == "synchronize") && body.pull_request.head.repo.full_name == "$GITHUB_USER/taxi-stage-config"
      bindings:
        - name: stage-ci-dryrun-from-pr-binding
      template:
        name: stage-ci-dryrun-from-pr-template
    - name: stage-cd-deploy-from-push
      interceptors:
        - cel:
            filter: (header.match("X-GitHub-Event", "push") && body.repository.full_name == "$GITHUB_USER/taxi-stage-config") && body.ref.startsWith("refs/heads/master")
      bindings:
        - name: stage-cd-deploy-from-push-binding
      template:
        name: stage-cd-deploy-from-push-template

```

* Run the following command to replace strings and apply yaml

**_NOTE:_**  Make sure `GITHUB_USER` envrionment variable is set.

```shell
cat temp.yaml  | sed s"/\$GITHUB_USER/$GITHUB_USER/" | oc apply -f -
```

## Expose webhook listener

Create `github-webhook-event-listener`

```shell
cat <<EOF | oc apply -f -
kind: Route
apiVersion: route.openshift.io/v1
metadata:
  name: github-webhook-event-listener
  labels:
    app.kubernetes.io/managed-by: EventListener
    app.kubernetes.io/part-of: Triggers
    eventlistener: cicd-event-listener
spec:
  to:
    kind: Service
    name: el-cicd-event-listener
    weight: 100
  port:
    targetPort: 8080
  wildcardPolicy: None
EOF
```
## Create github-auth secret

Create secret with the github token that you have regenerated/downloaded.

**_NOTE:_**  Make sure `GITHUB_USER` envrionment variable is set.
```shell
oc create secret generic ${GITHUB_USER}-github-auth --from-file="<path/to>/github-token.txt"
```

## Create a Webhook

Find out the `Payload URL` to be used in WebHook.   Run the following command to identify the external URL of the `github-webhook-event-listener`.   Add `http://` to the host to form `Payload URL` for Webhook.

```shell 
oc get route
```

![Screenshot](webhook-payload-url.png)


Goto your demo `taxi` Github repository.

```
https://github.com/$GITHUB_USER/taxi
```

Goto Settings to create a Webhook as follow

 ![Screenshot](create-webhooks.png)


# Test it

## Generate a Webhook Event

* Submit a Pull Request to your `taxi` GitHub repository
* Merge the Pull Request which should trigger a Pipeline Run in the CI Pipeline

## Re-generate Webhook Event without Pull Request

* Go back to the WebHooks Setting in your `taxi` GitHub repository and look for the last `Push` event.  You can re-deliever the event for testing without creating a Pull Request.

 ![Screenshot](resend-push-event.png)

## Use Tekton Dashboard to check Pipeline Runs

* Lookup the hostname of Tekton Dashboard

```shell
oc get route -n tekton-pipelines
```
 ![Screenshot](tekton-dashboard-hostname.png)

In this case, we put https://tekton-dashboard-tekton-pipelines.apps.gitops1.devcluster.openshift.com in the browser.  

* Pick the namespace according to the event generated.   E.g. `cicd-envrionment` if PR has been merged to the `taxi` master branch.

* Click `PipelineRuns`.  A list of PipelineRuns will be shown.  Click the new/executing PipelineRun


 ![Screenshot](pipeline-run-1.png)

* The status and the logs are shown.

 ![Screenshot](pipeline-run-2.png)
