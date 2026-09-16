# Questao 5

## Prompt:

```
# Before
Hoje o sistema possui o um manifesto kubernetes antigo sem as melhores práticas praticadas pela empresa. O arquivo é:
apiVersion: apps/v1
kind: Deployment
metadata:
  name: chronos-api
  namespace: production
spec:
  replicas: 1
  selector:
    matchLabels:
      app: chronos-api
  template:
    metadata:
      labels:
        app: chronos-api
    spec:
      containers:
      - name: api
        image: chronos-api:latest
        ports:
        - containerPort: 8080
        env:
        - name: DB_PASSWORD
          value: "P@ssw0rd2023!"
        - name: JWT_SECRET
          value: "hvt-jwt-prod-secret"

# After
Realizar a modernização do manifesto com as melhores práticas da empresa e do mercado atualmente, focando principalmente em ter alta disponibilidade, imagem versionada (nada de latest), secrets fora do manifest, resource requests e limits, liveness e readiness probes, securityContext não-root e as demais práticas de produção que hoje são padrão na empresa.

# Brigde
Atualize o manifesto seguindo as regras especificadas.


```

## Modelo

Manus 1.6 Lite.

## Output:

```
# Production baseline for chronos-api.
# Prerequisites:
#   - Namespace `production` must exist.
#   - Secret `chronos-api-secrets` must be provisioned by the approved secret manager
#     (External Secrets/Vault/CSI), with keys `DB_PASSWORD` and `JWT_SECRET`.
#   - Replace the example image tag with the release approved by CI/CD. Prefer an
#     immutable image digest in production, e.g. chronos-api:1.0.0@sha256:<digest>.
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: chronos-api
  namespace: production
automountServiceAccountToken: false
---
apiVersion: v1
kind: Service
metadata:
  name: chronos-api
  namespace: production
  labels:
    app.kubernetes.io/name: chronos-api
    app.kubernetes.io/component: api
    app.kubernetes.io/part-of: chronos
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: chronos-api
  ports:
    - name: http
      port: 8080
      targetPort: http
      protocol: TCP
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: chronos-api
  namespace: production
  labels:
    app.kubernetes.io/name: chronos-api
    app.kubernetes.io/component: api
    app.kubernetes.io/part-of: chronos
spec:
  replicas: 3
  revisionHistoryLimit: 5
  minReadySeconds: 10
  progressDeadlineSeconds: 600
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: chronos-api
  template:
    metadata:
      labels:
        app.kubernetes.io/name: chronos-api
        app.kubernetes.io/component: api
        app.kubernetes.io/part-of: chronos
    spec:
      serviceAccountName: chronos-api
      automountServiceAccountToken: false
      terminationGracePeriodSeconds: 30
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                topologyKey: kubernetes.io/hostname
                labelSelector:
                  matchLabels:
                    app.kubernetes.io/name: chronos-api
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: chronos-api
      containers:
        - name: api
          # Use a CI/CD-supplied immutable release tag or digest; never use `latest`.
          image: chronos-api:1.0.0
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          env:
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: chronos-api-secrets
                  key: DB_PASSWORD
                  optional: false
            - name: JWT_SECRET
              valueFrom:
                secretKeyRef:
                  name: chronos-api-secrets
                  key: JWT_SECRET
                  optional: false
          securityContext:
            allowPrivilegeEscalation: false
            privileged: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi
          startupProbe:
            httpGet:
              path: /healthz
              port: http
              scheme: HTTP
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 30
          readinessProbe:
            httpGet:
              path: /readyz
              port: http
              scheme: HTTP
            initialDelaySeconds: 5
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 3
            successThreshold: 1
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
              scheme: HTTP
            initialDelaySeconds: 15
            periodSeconds: 20
            timeoutSeconds: 2
            failureThreshold: 3
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir: {}
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: chronos-api
  namespace: production
  labels:
    app.kubernetes.io/name: chronos-api
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: chronos-api
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: chronos-api
  namespace: production
  labels:
    app.kubernetes.io/name: chronos-api
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: chronos-api
  minReplicas: 3
  maxReplicas: 10
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
        - type: Percent
          value: 100
          periodSeconds: 60
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
        - type: Percent
          value: 25
          periodSeconds: 60
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: 80
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: chronos-api
  namespace: production
  labels:
    app.kubernetes.io/name: chronos-api
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: chronos-api
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - ports:
        - protocol: TCP
          port: 8080
  egress:
    - ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
      # Cluster DNS pods are selected by the standard Kubernetes DNS labels in
      # most distributions; adjust this selector if the cluster uses another one.
      to:
        - namespaceSelector: {}
          podSelector:
            matchLabels:
              k8s-app: kube-dns
    # Application-specific database and external-service egress must be added
    # according to the approved network architecture; default-deny is intentional.

```

## Justificativa

O prompt segue a estrutura Before / After / Bridge: no Before foi apresentado o manifesto Kubernetes legado com anti-padrões, já no After foram definidos os requisitos de modernização e por fim no Bridge foi solicitada a atualização do manifesto conforme essas regras.
