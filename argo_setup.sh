
#!/bin/sh
if ! [ -x "$(command -v argocd)" ]; then
  echo 'Error: argocd is not installed see https://argoproj.github.io/argo-cd/getting_started/#2-download-argo-cd-cli' >&2
  exit 1
fi

oc new-project argocd
oc apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
HOSTNAME=`oc get route argocd-api -n argocd --template '{{.spec.host}}'`
PASSWORD=`oc get pods -n argocd -l app.kubernetes.io/name=argocd-server -o name | cut -d'/' -f 2`
EVENTLISTENER_URL=`oc get route github-webhook-event-listener -n cicd-environment --template '{{.spec.port.targetPort}}://{{.spec.host}}/'`
ARGOCD_URL=`oc get route argocd-api -n argocd --template '{{.spec.port.targetPort}}://{{.spec.host}}/'`
argocd login ${HOSTNAME} --username admin --password ${PASSWORD} --insecure
echo "You are now logged into the ArgoCD instance"
echo "Please change the password for the admin account the existing password is ${PASSWORD}"
echo "  $ argocd account update-password"
echo "Please create the application:"
echo "  $ argocd app create -f argocd/argo-app.yaml"
echo "And finally, you will need to add GitHub webhooks:"
echo "  for your main repository:"
echo "    ${EVENTLISTENER_URL}"
echo "  for your stage-config repository:"
echo "    ${EVENTLISTENER_URL}"
echo "    ${ARGOCD_URL}"
