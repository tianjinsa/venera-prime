"""Update the Prime AltStore feed from metadata without downloading IPA files."""

import json
import os
from pathlib import Path
import re
from urllib.parse import quote
from urllib.request import Request, urlopen


REPOSITORY = "venera-app/venera-prime"
BUNDLE_ID = "com.github.wgh136.venera.prime"


def prepare_description(text):
    text = re.sub(r"<[^<]+?>", "", text or "")
    text = re.sub(r"(?m)^#{1,6}\s?", "", text)
    return text.replace("**", "").replace("`", '"')


def fetch_latest_release(repo_url, tag=None):
    endpoint = f"tags/{quote(tag, safe='')}" if tag else "latest"
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "Venera-Prime-AltStore"}
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = Request(f"https://api.github.com/repos/{repo_url}/releases/{endpoint}", headers=headers)
    with urlopen(request, timeout=30) as response:
        return json.load(response)


def update_json_file_release(json_file, latest_release, repo_url=REPOSITORY):
    if isinstance(latest_release, list):
        latest_release = next(
            (item for item in latest_release if not item.get("draft") and not item.get("prerelease")),
            None,
        )
    if not latest_release:
        raise ValueError("No stable release found")
    if latest_release.get("draft") or latest_release.get("prerelease"):
        return False
    tag = latest_release["tag_name"]
    match = re.fullmatch(r"v?(\d+\.\d+\.\d+)", tag)
    if match is None:
        raise ValueError("Release tag is not a stable version")
    version = match.group(1)
    ipa_pattern = re.compile(rf"venera(?:-prime)?-ios-{re.escape(version)}\+(\d+)\.ipa")
    assets = [asset for asset in latest_release.get("assets", []) if ipa_pattern.fullmatch(asset["name"])]
    if len(assets) != 1:
        raise ValueError("Release must contain exactly one matching iOS IPA")
    ipa = assets[0]
    if not isinstance(ipa.get("size"), int) or ipa["size"] <= 0:
        raise ValueError("IPA size is missing from release metadata")
    build = ipa_pattern.fullmatch(ipa["name"]).group(1)
    published = latest_release["published_at"]
    description = prepare_description(latest_release.get("body"))
    path = Path(json_file)
    data = json.loads(path.read_text(encoding="utf-8"))
    app = data["apps"][0]
    # The inherited feed describes an app with a different bundle ID.
    if app.get("bundleIdentifier") != BUNDLE_ID:
        app["versions"] = []
        data["news"] = []
    url = f"https://github.com/{repo_url}"
    icon = f"https://raw.githubusercontent.com/{repo_url}/master/assets/app_icon.png"
    data.update({
        "name": "Venera Prime",
        "identifier": f"{BUNDLE_ID}.source",
        "website": url,
        "subtitle": "Venera Prime AltStore Source",
        "description": "AltStore source for Venera Prime releases.",
        "iconURL": icon,
    })
    entry = {
        "version": version,
        "buildVersion": build,
        "date": published[:10],
        "localizedDescription": description,
        "downloadURL": ipa["browser_download_url"],
        "size": ipa["size"],
        "minOSVersion": "14.0",
    }
    versions = [entry] + [item for item in app.get("versions", []) if item["version"] != version]
    versions.sort(key=lambda item: tuple(int(part) for part in item["version"].split(".")), reverse=True)
    newest = versions[0]
    app.update({
        "name": "Venera Prime",
        "bundleIdentifier": BUNDLE_ID,
        "developerName": "Venera Prime contributors",
        "iconURL": icon,
        "versions": versions,
        "version": newest["version"],
        "versionDate": newest["date"],
        "versionDescription": newest["localizedDescription"],
        "downloadURL": newest["downloadURL"],
        "size": newest["size"],
    })
    news_id = f"release-{tag}"
    news = {
        "appID": BUNDLE_ID,
        "caption": "A new Venera Prime version is available.",
        "date": published,
        "identifier": news_id,
        "notify": True,
        "tintColor": "#0784FC",
        "title": f"Venera Prime {version}",
        "url": f"{url}/releases/tag/{quote(tag, safe='')}",
    }
    data["news"] = [news] + [item for item in data.get("news", []) if item["identifier"] != news_id]
    if data == json.loads(path.read_text(encoding="utf-8")):
        return False
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return True


def main():
    repository = os.environ.get("GITHUB_REPOSITORY", REPOSITORY)
    release = fetch_latest_release(repository, os.environ.get("RELEASE_TAG"))
    changed = update_json_file_release("alt_store.json", release, repository)
    print("AltStore feed updated" if changed else "AltStore feed unchanged")


if __name__ == "__main__":
    main()
