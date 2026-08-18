# hepapi-case-study

Bu çalışma, [flask-mongodb](https://github.com/rianrajagede/flask-mongodb) örnek uygulamasının dockerize edilmesi, compose ve k8s'e kurulumu ve CI hattı ile ilgili detayları içermektedir.

---

## Hızlı başlangıç

**Gereksinimler:** Docker, `kubectl` ve `make` kurulu olmalı. `kind` ile `helm`'i ise `make preflight` kendisi kurar — sürümleri pinli kalsın diye proje içindeki `.bin/` altına; `make` hedefleri bunu bilir. Aynı araçları local terminalde kullanmak için:

```bash
export PATH="$PWD/.bin:$PATH"
```

**Docker Compose ile kurulum:**

```bash
cp .env.example .env      # değerler doldurulmalı: openssl rand -hex 24
docker compose up -d --build
```

→ [http://localhost:5050](http://localhost:5050)

**Kubernetes (kind) ile kurulum:**

```bash
make preflight            # kind + helm kurar (checksum doğrulamalı)
make all                  # cluster + registry + veritabanı + uygulama + Jenkins
```

→ [http://taskmanager.localtest.me:8080](http://taskmanager.localtest.me:8080)

**Günlük kullanım:**

```bash
make ci                   # Jenkins pipeline'ını tetikle ve takip et
make scale-demo           # HPA demosu: 60sn yük, sonra scale-down
make logs                 # üç replica'nın loglarını pod adıyla birlikte akıt
make port-forward         # ingress'i atlayıp localhost:8081'den eriş
make smoke                # helm test + dışarıdan istek ile doğrula
make lint                 # shellcheck + helm lint
make help                 # tüm hedefler
```

`make build && make deploy` imajı yerelde build edip doğrudan node'lara yükler —
hızlı geliştirme döngüsü için. `make ci` ise aynı işi cluster içindeki Jenkins'e
yaptırır: kaniko ile build, registry'ye push, oradan deploy. İkincisi gerçek
CI/CD yolu.

**Kaldırma/silme:** `make clean` (cluster'ı ve yerel image'ları siler)

---

## Mimari

```
  tarayıcı
     │  http://taskmanager.localtest.me:8080
     ▼
┌───────────────────────────────────────────────────────────────────────┐
│ kind cluster — 1 control-plane + 3 worker                             │
│                                                                       │
│   ingress-nginx  ──►  Service (ClusterIP)  ──►  app pod × 3           │
│   control-plane'de        :80 → :5000          topologySpread:        │
│                                                her node'da 1          │
│                                                      │                │
│                        mongodb://…-0,…-1,…-2/?replicaSet=rs0          │
│                                                      ▼                │
│                                         MongoDB StatefulSet × 3       │
│                                         PRIMARY + 2 SECONDARY         │
│                                         antiAffinity: her node'da 1   │
│                                         pod başına ayrı PVC           │
│                                                                       │
│   Jenkins (jenkins ns) ──build──► registry (registry ns) ──pull──►    │
│   pipeline as code                cluster içi                app pod  │
└───────────────────────────────────────────────────────────────────────┘
```


| Bileşen              | Seçim                                              |
| -------------------- | -------------------------------------------------- |
| Local k8s cluster    | Kind — 1 control-plane + 3 worker                  |
| Uygulama paketleme   | Helm chart (`charts/taskmanager`)                  |
| Veritabanı           | Bitnami MongoDB chart 19.1.30, replica set (3 üye) |
| Trafik giriş noktası | Ingress-nginx (yedek yol: `make port-forward`)     |
| CI/CD                | Cluster içi Jenkins (JCasC + kaniko + registry)    |


---

## Uygulama kaynağında yapılan değişiklik

`classes.py` ve `templates/home.html` **hiç değiştirilmedi**. `run.py`'da production hassasiyeti gerektirdiği için iki müdahale yapıldı:

**1. Konfigürasyon (3 satır).** `SECRET_KEY`, `MONGODB_URI` ve `FLASK_DEBUG` artık ortam değişkeninden okunuyor, üçü de mevcut değerleri varsayılan alıyor — yani konfigürasyonsuz çalıştırıldığında davranış upstream ile birebir aynı. Bu olmadan gizli bilgiler kodda kalır ve uygulama farklı bir veritabanına yönlendirilemezdi.

**2. Eşzamanlılık (2 nokta).** Uygulamayı birden fazla replica ile çalıştırmak upstream haliyle veri bozuyordu: `task_id` sayacı modül import edilirken korumasız oluşturuluyor (aynı anda başlayan pod'lar birden fazla kayıt ekler) ve oku-artır-yaz şeklinde güncelleniyordu (eşzamanlı istekler aynı id'yi alır, bir task silinince diğeri de silinir). Her iki işlem de MongoDB'nin atomik operasyonlarına taşındı, böylece sıralamayı uygulama değil veritabanı garanti ediyor. (3 replica'ya 40 eşzamanlı istek atılarak doğrulandı → 40 benzersiz id, 0 duplicate.)

---

## Production hassasiyetiyle yapılan dokunuşlar

**Dockerize**

- Multi-stage build: derleyici (gcc) yalnızca pymongo'nun derlendiği aşamada var, runtime imajında yok — daha küçük imaj, daha küçük saldırı yüzeyi.
- Base image **digest** ile pinli, tag ile değil: tag zamanla farklı bir imaja işaret edebilir, digest hep aynı byte'lara çözülür —build her seferinde bugünkü gibi tekrarlanır.
- İmajın içinde `USER` ile root olmayan bir kullanıcı tanımlı; bu k8s'teki `runAsNonRoot`'tan bağımsız bir katman — imaj compose'da ya da k8s dışında bir yerde çalıştırılsa bile root olarak başlamaz.
- `HEALTHCHECK` imajda tanımlı: Compose bunu okuyor; K8s okumadığı için probe'lar chart'ta ayrıca mevcut.
- `docker/entrypoint.sh` veritabanının açılmasını bekleyip `exec` ile uygulamaya devrediyor — süreç PID 1 olarak SIGTERM'i doğru alıyor.
- `.dockerignore` build context'i imajın gerçekten ihtiyaç duyduğu dosyalarla sınırlıyor.
- Compose tarafında `depends_on` healthcheck'e bağlı app, veritabanı sağlıklı olmadan başlamıyor ve uygulama kullanıcısını `docker/mongo-init.js` en az yetkiyle oluşturuyor.

**Kimlik doğrulama ve gizli bilgiler**

- MongoDB varsayılanda şifresizdi → auth açıldı; `root` yerine sadece `TaskManager`'da `readWrite` yetkili ayrı bir uygulama kullanıcısı var.
- Şifreler koddan çıkarıldı: Compose tarafında gitignore'lu `.env`, Kubernetes tarafında Secret. `SECRET_KEY` ve `MONGODB_URI` artık hardcoded değil.
- Bağlantı adresi Deployment'ta `$(VAR)` referanslarıyla kuruluyor; şifre hiçbir manifest'te veya git geçmişinde görünmüyor. CI bunu bozacak değişikliği yakalıyor.
- `SECRET_KEY` her `helm upgrade`'de yeniden üretilmiyor; aksi halde açık her tarayıcı sekmesinin CSRF token'ı geçersiz olurdu.
- Credential script'i idempotent: MongoDB kullanıcıyı yalnızca ilk açılışta oluşturduğu için Secret'ın kazara yenilenmesi uygulamayı kilitlerdi.

**Yüksek erişilebilirlik**

- Uygulama upstream haliyle çok pod'da veri bozuyordu; sayaç atomik operasyonlara taşınarak 3 replica mümkün hale getirildi.
- Pod'lar node'lara dengeli dağıtıldı: uygulamada `topologySpreadConstraints` (`maxSkew: 1` — en dolu ve en boş node arasındaki izinli fark, `DoNotSchedule` — aşılırsa pod Pending kalır), veritabanında `podAntiAffinity: hard`. İkisi de her node'da bir pod bırakıyor; ilki node sayısını aşan replica'ya izin veriyor, ikincisi quorum gereği katı sınır koyuyor.
- Deploy `maxSurge: 0` ile ilerliyor (rollout'ta hedefin üstüne çıkacak fazladan pod sayısı) — spread kuralı yalnızca schedule anını bağladığı için, surge'lü bir rollout dağılımı kalıcı olarak bozardı. (Eşit dağılması için yapıldı, daha fazla pod'lu case'ler için maxSurge değeri artırılabilir.)
- MongoDB'ye `PodDisruptionBudget minAvailable: 2` verildi: 3 üyeli replica set quorum'unu korumak için, çünkü aynı anda iki üye tahliye edilirse primary seçilemez ve veritabanı salt-okunur kalır.

**Çalışma zamanı güvenliği**

- Uygulama pod'u: `runAsNonRoot`, `readOnlyRootFilesystem`, tüm capability'ler düşürülmüş,  
`seccompProfile: RuntimeDefault`, `automountServiceAccountToken: false`.
- Veritabanı portu host'a publish edilmiyor.
- NetworkPolicy açık: default deny, sadece ingress controller'dan gelen ve MongoDB ile DNS'e giden trafiğe izin verildi. (Başka bir namespace'ten erişim policy öncesi çalışıyordu, sonrasında engellendiği doğrulandı.)
- Aynı securityContext standardı yalnız uygulamada değil: registry, Jenkins ve helm test pod'ları da non-root + seccomp + capability drop ile çalışıyor.
- Jenkins controller'da build çalışmıyor (`numExecutors: 0`); her build tek kullanımlık agent pod'unda.

**Tekrarlanabilirlik**

- Uygulama yolundaki image'lar (base image, MongoDB, kind node) digest ile; CI/altyapı image'ları ve araçlar sürüm tag'i ile pinli. İndirilen binary'ler checksum doğrulanıyor.
- Her build benzersiz image tag'i alıyor; aynı tag tekrar kullanılsa `imagePullPolicy: IfNotPresent` yüzünden pod sessizce eski kodu çalıştırırdı.
- Tüm otomasyon script'leri idempotent — tekrar çalıştırmak durumu bozmuyor.

---

## Production veritabanı mimarisi

MongoDB, 3 üyeli bir replicaset olarak çalışıyor. **StatefulSet** tercih edildi: her üyeye kalıcı bir kimlik verir (sabit ad + kendi PVC'si) ve o kimliğin ikinci bir kopyasının aynı anda çalışmasına izin vermez. Deployment'ta pod'lar birbirinin yerine geçebilir — sabit bir kimlik kavramı yok, bu yüzden node partition'da eskisi hâlâ çalışırken yenisi başka node'da açılabilir. Aynı veri dizinini açmaya çalışan ikinci `mongod` dosya kilidine takılıp başlayamaz, veritabanı erişilemez hale gelebilirdi. Bu nedenle statefulset ile ilerlendi.


| Ayar           | Değer                                                                               |
| -------------- | ----------------------------------------------------------------------------------- |
| Topoloji       | `rs0` — 1 PRIMARY + 2 SECONDARY, üçü de oy veren ve seçilebilir                     |
| Depolama       | `volumeClaimTemplates` ile pod başına ayrı PVC                                      |
| Dağıtım        | `podAntiAffinity: hard` — her üye ayrı node'da                                      |
| Kesinti durumu | `PodDisruptionBudget minAvailable: 2` (quorum korunur)                              |
| Bağlantı       | URI tüm üyeleri listeler + `replicaSet=rs0` → sürücü yazmayı PRIMARY'ye yönlendirir |


> **Chart'ta bir sorun tespit edildi:** Bitnami chart'ı 2. ve 3. üyeyi oy hakkı olmadan (`votes: 0`) kuruyor — yani 3 pod var ama failover yok. Chart'ın bunu düzeltmek için sunduğu ayar da çalışmıyor, bu yüzden üye terfisi `scripts/deploy-database.sh` içinde açıkça ve idempotent şekilde yapıldı.

**Gerçek failover testi yapıldı:** PRIMARY pod'u silindiğinde yeni PRIMARY seçildi, uygulama kesintisiz hizmet vermeye devam etti (0 restart), veri korundu ve failover sonrası yazma işlemleri çalıştı.

---

## Probe tasarımı

Uygulamanın tek endpoint'i `/` ve bu endpoint MongoDB'ye sorgu atıyor.


| Probe     | Tip      | Gerekçe                                                                                                                                   |
| --------- | -------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| startup   | HTTP `/` | Veritabanı beklemesini tolere eder, diğer iki probe'u geciktirir.                                                                         |
| readiness | HTTP `/` | MongoDB'ye **bilerek** bağımlı: DB yoksa uygulama gerçekten hizmet veremez, endpoint'lerden çıkması doğru sinyaldir.                      |
| liveness  | TCP      | MongoDB'ye **bilerek** dokunmaz. HTTP olsaydı her DB kesintisinde tüm pod'lar restart olur, zaten bozuk sisteme cold start eklenebilirdi. |


**Doğrulandı:** MongoDB 3→0 ölçeklendiğinde uygulama `NotReady` oldu ve service endpoint'lerinden çıktı ama **restart olmadı**; 0→3 geri ölçeklendiğinde kendiliğinden toparlandı, restart sayısı yine 0'dı.

---

## Uygulama yüksek erişilebilirliği

3 replica, her biri ayrı node'da.


| Ayar    | Değer                                                       |
| ------- | ----------------------------------------------------------- |
| Dağıtım | `topologySpreadConstraints` — `maxSkew: 1`, `DoNotSchedule` |
| PDB     | `PodDisruptionBudget minAvailable: 2`                       |
| Deploy  | `RollingUpdate` + `maxSurge: 0`                             |


`maxSurge: 0` bilinçli: topology spread yalnızca schedule anını bağlar, çalışan pod'ları yeniden dengelemez. Surge ile yeni pod eski pod hâlâ node'unu tutarken yerleşir ve dağılım kalıcı olarak bozulur. Önce node'u boşaltmak bunu önlüyor.

**Doğrulandı:** üst üste iki rolling restart sonrası dağılım 1/1/1 kaldı, 150 isteğin 150'si HTTP 200 döndü.

`autoscaling`: `cluster-up.sh`'ın kurduğu metrics-server'a dayanıyor ve `make scale-demo` yük üretip HPA'nın 3→6→3 ölçeklemesini gösteriyor.

---

## CI/CD — cluster içi Jenkins

Pipeline, cluster'ın **içinde** çalışan bir Jenkins tarafından yürütülüyor. Bu tercih bilinçli: dışarıdaki bir CI servisi yerel cluster'a erişemez, in-cluster Jenkins ise ServiceAccount ve RBAC ile doğrudan deploy edebiliyor.

```
make ci
   │
   ▼
Jenkins (jenkins namespace)  ──► agent pod (tools + kaniko)
                                     │
   Checkout ─ Verify ─ Build image ─ Deploy ─ Verify deployment
                          │            │
                    kaniko push    helm upgrade --atomic
                          ▼            ▼
                  cluster içi      taskmanager
                    registry        namespace
```


| Stage               | Yaptığı                                                                  |
| ------------------- | ------------------------------------------------------------------------ |
| `Version`           | `Chart.yaml`'dan sürümü okur, semver doğrular, image tag'ini üretir      |
| `Checkout`          | Cluster'a mount edilmiş çalışma ağacını agent'a kopyalar                 |
| `Verify`            | Paralel: `helm lint`, manifest render, credential sızıntı testi          |
| `Build image`       | **kaniko** ile docker daemon olmadan build, cluster içi registry'ye push |
| `Deploy`            | `helm upgrade --install --atomic`                                        |
| `Verify deployment` | `rollout status` + `helm test`                                           |


**Everything as Code:** `Jenkinsfile` pipeline'ı, `kubernetes/jenkins/casc.yaml` ise Jenkins'in kendisini tanımlıyor — güvenlik, agent cloud'u ve job tanımı dahil. UI'dan tıklanarak yapılan hiçbir ayar yok; controller silinip yeniden kurulsa aynı şekilde ayağa kalkar. Job DSL için script security bilinçli kapalı: seed job'ın kaynağı cluster'a read-only mount edilen repo içeriği, yani zaten güvenilen kod; pipeline'ın kendisi sandbox'ta koşmaya devam ediyor.

**Neden kaniko:** Pod içinde docker daemon yok. kaniko imajı dosya sisteminden build edip doğrudan registry'ye gönderiyor, ayrıcalıklı container veya docker socket mount'u gerekmiyor.

**Cluster içi registry:** kaniko'nun build ettiği imajı bir yere push etmesi gerekiyor; bunun için `registry` namespace'inde **CNCF Distribution** (`registry:3.0.0`) çalışıyor — OCI Distribution Spec'in referans implementasyonu, Harbor gibi kurumsal registry'ler de çekirdeğinde bunu kullanıyor. Böylece CI/CD döngüsünün tamamı cluster'ın içinde kapanıyor: dışarıya imaj yayınlamak, registry kimlik bilgisi taşımak veya internet erişimine bağlı olmak gerekmiyor.

Node'ların bu registry'den pull edebilmesi için `scripts/deploy-registry.sh` her node'a bir `hosts.toml` yazıyor — containerd 2.x satır içi `registry.mirrors` ayarını kaldırdığı için per-registry konfigürasyon artık dosyadan okunuyor. Depolama bilinçli olarak `emptyDir`: imajlar cluster kadar yaşıyor, registry yeniden başlarsa bir sonraki pipeline çalışması onu yeniden dolduruyor. Gerçek production'da buranın yerini Harbor / ECR / GHCR alırdı; buradaki tercih case'in dış bir servise bağlı olmadan, tamamen self-contained çalışabilmesi için.

**RBAC:** Jenkins'e cluster geneli yetki verilmedi: kendi namespace'inde agent pod'u yönetme, `taskmanager` namespace'inde ise yalnızca chart'ın dokunduğu kaynak tiplerini yönetme yetkisi var.

**Semantic versioning.** Sürümün tek kaynağı `Chart.yaml`: `version` chart'ın şablonlarını, `appVersion` uygulamayı takip ediyor. Pipeline ikisinin de geçerli semver olduğunu doğruluyor, aksi halde build kırılıyor — bir chart hiçbir zaman olmadığı bir sürümü iddia edemiyor. Image iki tag'le push ediliyor: `0.1.0-build.<N>` (deployment'ın kullandığı, benzersiz; `<N>` = Jenkins build numarası) ve `0.1.0` (insan okuması için, kayan). Deployment'ın benzersiz olanı kullanması şart —  
`imagePullPolicy: IfNotPresent` ile kayan tag sessizce eski kodu çalıştırırdı.

---

## Script'ler


| Dosya                           | İşlevi                                                                                  |
| ------------------------------- | --------------------------------------------------------------------------------------- |
| `scripts/lib.sh`                | Ortak yardımcılar ve tüm sabitlenmiş sürümler (tek kaynak)                              |
| `scripts/preflight.sh`          | Araç kontrolü; eksik kind/Helm'i checksum doğrulayarak `.bin/`'e kurar                  |
| `scripts/cluster-up.sh`         | kind cluster'ı, ingress controller'ı, metrics-server'ı ve cluster içi registry'yi kurar |
| `scripts/cluster-down.sh`       | Cluster'ı siler (`--purge` ile yerel image'ları da)                                     |
| `scripts/build-and-load.sh`     | Image'ı build edip `kind load` ile node'lara yükler                                     |
| `scripts/create-credentials.sh` | Paylaşımlı MongoDB Secret'ını üretir, mevcut şifreleri korur                            |
| `scripts/deploy-database.sh`    | MongoDB chart'ını kurar ve tüm üyeleri oy verebilir hale getirir                        |
| `scripts/deploy-app.sh`         | Uygulama chart'ını kurar                                                                |
| `scripts/smoke-test.sh`         | `helm test` hook'unu ve dışarıdan isteği doğrular                                       |
| `scripts/deploy-registry.sh`    | Cluster içi registry'yi kurar, node'lara containerd ayarını yazar                       |
| `scripts/deploy-jenkins.sh`     | Jenkins'i RBAC ve JCasC ile kurar                                                       |
| `scripts/run-pipeline.sh`       | Pipeline'ı tetikler ve bitene kadar takip eder                                          |
| `scripts/scale-demo.sh`         | HPA'yı yük üreterek tetikler, scale-up ve scale-down'ı gösterir                         |


Makefile hedefleri: `preflight up down clean build credentials deploy-db deploy jenkins ci smoke scale-demo all lint template logs port-forward compose-up compose-down`
(`make help` listeler; `make jenkins` yalnız Jenkins'i yeniden kurar).

---

## Bilinen sınırlamalar

- Uygulama Flask'ın development server'ı ile çalışıyor — upstream `run.py`'daki `app.run()` bloğuna dokunmamak için gunicorn'a geçilmedi. Production öncesi bu geçiş yapılabilir: `gunicorn run:app` (Dockerfile CMD + requirements değişikliği yeterli).
- Cluster içi registry TLS'siz; kaniko ve containerd bu yüzden insecure modda konuşuyor. Production'da yerini TLS'li Harbor / ECR / GHCR alır.
- Registry depolaması `emptyDir` — imajlar cluster ömrüyle sınırlı, sonraki pipeline yeniden dolduruyor (bilinçli tercih).
- Jenkinsfile, Git remote olmadığı için cluster'a mount edilen çalışma ağacından okunuyor; remote'a geçiş JCasC'de tek satır bir güncelleme yapılmalı.
- Jenkins plugin sürümleri pinli değil (çözüm jenkins-plugin-cli'ya bırakıldı); tam tekrarlanabilirlik için plugin'leri içeren özel bir imaj build edilebilir.
- Monitoring/alerting, TLS ve veritabanı yedekleme kapsam dışı — production'da eklenecek ilk kalemler olabilir.
- Gizli bilgiler compose tarafında `.env`'de, k8s tarafında native secret'ta duruyor (ikisi de düz metin/base64, şifreli değil). Gerçek production'da AWS Secrets Manager, Vault veya External Secrets Operator gibi bir servisten okunabilir; buradaki kapsam için secret yeterli görüldü.

