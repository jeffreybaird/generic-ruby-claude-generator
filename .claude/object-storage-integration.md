# Object Storage Integration

> **Optional module.** Include if your app stores files/blobs in object storage.

Direct-browser uploads to an S3-compatible object store — **file bytes never pass
through your app server**. Works with AWS S3, Cloudflare R2, DigitalOcean Spaces,
and MinIO (all speak the S3 API).

This follows the base pattern in `external-service-integration.md` (one client
class behind an injectable seam; stub it in specs; secrets via ENV/credentials).

> **Baseline:** Wrap every third-party API behind a client class · Faraday (~> 2) for HTTP with retry/timeout middleware · verify webhook signatures over the raw body, then process async via a background job · secrets via ENV/credentials.

---

## Choosing the storage layer

| Approach | When | Notes |
|---|---|---|
| **Active Storage** (Rails default) <span title="stable">`[stable]`</span> | Rails 8 apps | Built-in. Direct uploads, variants, multiple services. Manages its own keys (see caveat). [guide](https://guides.rubyonrails.org/active_storage_overview.html) |
| [`shrine`](https://github.com/shrinerb/shrine) `~> 3` <span title="stable">`[stable]`</span> | Sinatra, or Rails apps needing fine-grained control | Plugin-based; explicit presigned uploads; you control keys. |
| [`aws-sdk-s3`](https://github.com/aws/aws-sdk-ruby) `~> 1` <span title="stable">`[stable]`</span> | Sinatra / advanced; lowest level | Full S3 surface (presign, multipart, lifecycle). Wrap behind `MyApp::Storage::Client`. |

**Rails: default to Active Storage.** **Sinatra / advanced: shrine or
aws-sdk-s3.** Pick one — don't run two side by side.

---

## Presigned / Direct Uploads — the core principle

The browser uploads **directly to the bucket**. The app server only mints a
short-lived credential. Bytes never transit your app.

```
Browser                     App server                  Bucket (S3/R2/Spaces)
  |                            |                              |
  |-- POST /uploads/sign ----->|                              |
  |                            |-- presign PUT (server-side)  |
  |<-- { url, key } -----------|                              |
  |-- PUT <signed-url> (file) ------------------------------->|
  |<-- 200 OK -----------------------------------------------|
  |-- POST /uploads/confirm -->| (persist key to DB)          |
```

### Rails — Active Storage direct upload

Active Storage ships a `DirectUpload` JS helper that requests a signed URL from
the built-in `/rails/active_storage/direct_uploads` endpoint, PUTs the file to the
bucket, then hands you a `signed_id` to attach.

```ruby
# config/storage.yml
amazon:
  service: S3
  access_key_id: <%= ENV["STORAGE_ACCESS_KEY_ID"] %>
  secret_access_key: <%= ENV["STORAGE_SECRET_ACCESS_KEY"] %>
  region: <%= ENV["STORAGE_REGION"] %>
  bucket: <%= ENV["STORAGE_BUCKET"] %>
  # R2 / Spaces / MinIO: add `endpoint:` to point at the S3-compatible host
```

```erb
<%= form.file_field :avatar, direct_upload: true %>
```

```ruby
class User < ApplicationRecord
  has_one_attached :avatar
end
```

### Sinatra / advanced — presigned PUT behind one client

```ruby
# lib/my_app/storage/client.rb
require "aws-sdk-s3"

module MyApp
  module Storage
    class Client
      DEFAULT_EXPIRY = 900   # 15 min — covers pick-file → PUT-complete

      def initialize(s3: nil)
        @s3 = s3 || Aws::S3::Resource.new(
          region:   ENV.fetch("STORAGE_REGION"),
          endpoint: ENV["STORAGE_ENDPOINT"],          # set for R2/Spaces/MinIO; omit for AWS
          access_key_id:     ENV.fetch("STORAGE_ACCESS_KEY_ID"),
          secret_access_key: ENV.fetch("STORAGE_SECRET_ACCESS_KEY")
        )
      end

      # Short-lived URL the browser PUTs to directly.
      def presigned_put_url(key:, content_type:, expires_in: DEFAULT_EXPIRY)
        obj = @s3.bucket(bucket).object(key)
        Success(obj.presigned_url(:put, expires_in:, content_type:))
      rescue Aws::Errors::ServiceError => e
        Failure([:external_service_error, e.message])
      end

      # Short-lived read URL for a PRIVATE object.
      def presigned_get_url(key:, expires_in: 300)
        Success(@s3.bucket(bucket).object(key).presigned_url(:get, expires_in:))
      end

      def delete(key:)
        @s3.bucket(bucket).object(key).delete
        :ok
      rescue Aws::Errors::ServiceError => e
        Failure([:external_service_error, e.message])
      end

      private

      def bucket = ENV.fetch("STORAGE_BUCKET")
    end
  end
end
```

```ruby
# Sign endpoint stays thin — call the client, return url + key
post "/uploads/sign" do
  key    = MyApp::Storage.key_for(account: Current.account, kind: "avatar", filename: params[:filename])
  result = MyApp::Storage::Client.new.presigned_put_url(key:, content_type: params[:content_type])
  case result.to_tuple
  in [:ok, url] then json(url:, key:)
  in [:error, :external_service_error, _] then halt 502
  end
end
```

---

## Key Layout

Use a predictable, collision-safe, unguessable structure:

```
account/<id>/<kind>/<uuid>.<ext>
```

```
account/42/avatar/550e8400-e29b-41d4-a716-446655440000.png
```

- `account/<id>` — namespaces by tenant (no cross-tenant key collision)
- `<kind>` — asset type (`avatar`, `cover`, `attachment`, …)
- `<uuid>` — generated server-side; unguessable, no name collisions

```ruby
def self.key_for(account:, kind:, filename:)
  ext = File.extname(filename).delete(".").downcase
  "account/#{account.id}/#{kind}/#{SecureRandom.uuid}.#{ext}"
end
```

> **Active Storage caveat.** Active Storage **generates its own random blob keys**
> and stores the original-filename ↔ key mapping in `active_storage_blobs`. You do
> **not** control the bucket key with stock Active Storage. The custom
> `account/<id>/<kind>/<uuid>.<ext>` layout above applies to the **shrine /
> aws-sdk-s3 presigned path**. If you need that exact layout on Rails, implement a
> custom service or override key generation — otherwise let Active Storage manage
> keys and scope access through your DB associations.

---

## Public vs Private Buckets

| Bucket | Use case | Read access |
|---|---|---|
| **Public** | Images, thumbnails, static assets | Object URL is directly shareable; no signing to read |
| **Private** | Documents, user data, anything sensitive | Mint a **presigned GET** server-side, short expiry |

```ruby
# Private read — short-lived signed GET, never a permanent public URL
result = MyApp::Storage::Client.new.presigned_get_url(key: doc.storage_key, expires_in: 300)
```

Default presigned lifetime: **15 minutes (900 s)** for PUT, **5 minutes (300 s)**
for private GET. Raise PUT expiry only for genuinely large uploads on slow links.

---

## CORS (required for direct upload)

Because the browser PUTs to the bucket host (a different origin), the bucket needs
a CORS policy or the preflight `OPTIONS` fails.

```json
[
  {
    "AllowedOrigins": ["https://app.example.com", "http://localhost:3000"],
    "AllowedMethods": ["PUT", "GET", "HEAD"],
    "AllowedHeaders": ["*"],
    "ExposeHeaders": ["ETag"],
    "MaxAgeSeconds": 3000
  }
]
```

**Debugging:** DevTools → Network → find the `OPTIONS` preflight to the bucket
host. A missing `Access-Control-Allow-Origin` in the response means the bucket
rejected the preflight — fix `AllowedOrigins`. Rails Active Storage direct upload
needs `PUT` allowed and `Origin`/`Content-Type` headers permitted.

---

## Secrets

| Variable | Required | Example | Purpose |
|---|---|---|---|
| `STORAGE_ACCESS_KEY_ID` | Yes | `AKIA…` | Access key |
| `STORAGE_SECRET_ACCESS_KEY` | Yes | `wJalr…` | Secret |
| `STORAGE_BUCKET` | Yes | `my-app-assets` | Bucket name |
| `STORAGE_REGION` | Yes | `us-east-1` / `auto` | Region |
| `STORAGE_ENDPOINT` | For R2/Spaces/MinIO | `https://<acct>.r2.cloudflarestorage.com` | S3-compatible endpoint (omit for AWS) |

ENV by default; Rails may use encrypted credentials. Never commit credentials.

```ruby
# ❌
secret_access_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"

# ✅
secret_access_key: ENV.fetch("STORAGE_SECRET_ACCESS_KEY")
```

---

## Testing

Specs **never touch a real bucket.** Stub the client (or, for Active Storage, use
the `:test` service which writes to `tmp/storage`).

```ruby
RSpec.describe "upload signing" do
  it "returns a presigned PUT url for a tenant-scoped key" do
    client = instance_double(MyApp::Storage::Client)
    allow(client).to receive(:presigned_put_url)
      .and_return(Success("https://bucket.example.com/key?X-Amz-Signature=abc"))

    result = client.presigned_put_url(key: "account/1/avatar/uuid.png", content_type: "image/png")

    expect(result.value!).to include("X-Amz-Signature")
  end
end
```

```ruby
# config/environments/test.rb — Active Storage uses the local test service
config.active_storage.service = :test
```

```ruby
# spec — Active Storage attach without S3
it "attaches an avatar" do
  user.avatar.attach(io: StringIO.new("png"), filename: "a.png", content_type: "image/png")
  expect(user.avatar).to be_attached
end
```

WebMock can block any stray S3 call so a leak fails loudly rather than hitting the
network.

---

## Cross-References

| Topic | File |
|---|---|
| Base client / webhook pattern | `external-service-integration.md` |
| Payment provider integration | `payment-integration.md` |
| Result tuples, events, audit | `architecture-decisions.md` |
| Where storage calls belong | `separation-of-concerns.md` |
| Testing patterns | `testing.md` |
