require "test_helper"

class Api::V1::BadgesControllerTest < ActionDispatch::IntegrationTest
  test "show returns a badge" do
    creator = create_user
    owner = create_user
    bc = create_badge_class(creator: creator)
    badge = create_badge(badge_class: bc, creator: creator, owner: owner)

    get "/api/v1/badges/#{badge.id}", headers: auth_headers(owner)
    assert_response :success
    assert_equal badge.id, json_response["id"]
  end

  test "index only returns minted badges, filterable by user_id/owned/created/owner_handle/badge_class_id" do
    creator = create_user
    owner = create_user
    bc = create_badge_class(creator: creator)
    minted = create_badge(badge_class: bc, creator: creator, owner: owner, status: "minted")
    burned = create_badge(badge_class: bc, creator: creator, owner: owner, status: "burned")

    get "/api/v1/badges", headers: auth_headers(owner)
    ids = json_response["data"].map { |b| b["id"] }
    assert_includes ids, minted.id
    assert_not_includes ids, burned.id

    get "/api/v1/badges", params: { user_id: owner.id, owned_badges: "1" }, headers: auth_headers(owner)
    ids = json_response["data"].map { |b| b["id"] }
    assert_includes ids, minted.id

    get "/api/v1/badges", params: { user_id: creator.id, created_badges: "1" }, headers: auth_headers(owner)
    ids = json_response["data"].map { |b| b["id"] }
    assert_includes ids, minted.id

    get "/api/v1/badges", params: { owner_handle: owner.name }, headers: auth_headers(owner)
    ids = json_response["data"].map { |b| b["id"] }
    assert_includes ids, minted.id

    get "/api/v1/badges", params: { badge_class_id: bc.id }, headers: auth_headers(owner)
    ids = json_response["data"].map { |b| b["id"] }
    assert_includes ids, minted.id
  end

  test "update sets display, allowed for creator or owner (BadgePolicy#update?)" do
    creator = create_user
    owner = create_user
    outsider = create_user
    bc = create_badge_class(creator: creator)
    badge = create_badge(badge_class: bc, creator: creator, owner: owner)

    patch "/api/v1/badges/#{badge.id}", params: { display: "pinned" }, headers: auth_headers(outsider)
    assert_response :forbidden

    patch "/api/v1/badges/#{badge.id}", params: { display: "pinned" }, headers: auth_headers(owner)
    assert_response :success
    assert_equal "pinned", badge.reload.display

    patch "/api/v1/badges/#{badge.id}", params: { display: "hidden" }, headers: auth_headers(creator)
    assert_response :success
    assert_equal "hidden", badge.reload.display
  end

  test "transfer requires ownership, transferability, and minted/accepted status" do
    creator = create_user
    owner = create_user
    target = create_user
    bc = create_badge_class(creator: creator, transferable: true)
    badge = create_badge(badge_class: bc, creator: creator, owner: owner)

    # non-owner forbidden
    post "/api/v1/badges/#{badge.id}/transfer", params: { target: target.name }, headers: auth_headers(creator)
    assert_response :forbidden

    # target not found
    post "/api/v1/badges/#{badge.id}/transfer", params: { target: "nobody" }, headers: auth_headers(owner)
    assert_response :unprocessable_entity
    assert_match "target not found", json_response["error"]

    # self-transfer rejected
    post "/api/v1/badges/#{badge.id}/transfer", params: { target: owner.name }, headers: auth_headers(owner)
    assert_response :unprocessable_entity
    assert_match "cannot transfer to self", json_response["error"]

    # success
    post "/api/v1/badges/#{badge.id}/transfer", params: { target: target.name }, headers: auth_headers(owner)
    assert_response :success
    assert_equal target.id, badge.reload.owner_id
  end

  test "transfer rejects a non-transferable badge_class" do
    creator = create_user
    owner = create_user
    target = create_user
    bc = create_badge_class(creator: creator, transferable: false)
    badge = create_badge(badge_class: bc, creator: creator, owner: owner)

    post "/api/v1/badges/#{badge.id}/transfer", params: { target: target.name }, headers: auth_headers(owner)
    assert_response :unprocessable_entity
    assert_match "not transferable", json_response["error"]
  end

  test "transfer rejects a burned badge" do
    creator = create_user
    owner = create_user
    target = create_user
    bc = create_badge_class(creator: creator, transferable: true)
    badge = create_badge(badge_class: bc, creator: creator, owner: owner, status: "burned")

    post "/api/v1/badges/#{badge.id}/transfer", params: { target: target.name }, headers: auth_headers(owner)
    assert_response :unprocessable_entity
    assert_match "not owned/accepted", json_response["error"]
  end

  test "burn requires ownership and minted status, is terminal" do
    creator = create_user
    owner = create_user
    outsider = create_user
    bc = create_badge_class(creator: creator)
    badge = create_badge(badge_class: bc, creator: creator, owner: owner)

    post "/api/v1/badges/#{badge.id}/burn", headers: auth_headers(outsider)
    assert_response :forbidden

    post "/api/v1/badges/#{badge.id}/burn", headers: auth_headers(owner)
    assert_response :success
    assert_equal "burned", badge.reload.status

    # burning an already-burned badge fails — no transition out of burned
    post "/api/v1/badges/#{badge.id}/burn", headers: auth_headers(owner)
    assert_response :unprocessable_entity
    assert_match "not minted", json_response["error"]
  end

  test "swap_code requires ownership, minted/accepted status, and transferability" do
    creator = create_user
    owner = create_user
    outsider = create_user
    bc = create_badge_class(creator: creator, transferable: true)
    badge = create_badge(badge_class: bc, creator: creator, owner: owner)

    post "/api/v1/badges/#{badge.id}/swap_code", headers: auth_headers(outsider)
    assert_response :forbidden

    post "/api/v1/badges/#{badge.id}/swap_code", headers: auth_headers(owner)
    assert_response :success
    assert json_response["token"].present?
    assert_equal badge.id, json_response["badge_id"]
  end

  test "swap_code rejects a non-transferable badge_class" do
    creator = create_user
    owner = create_user
    bc = create_badge_class(creator: creator, transferable: false)
    badge = create_badge(badge_class: bc, creator: creator, owner: owner)

    post "/api/v1/badges/#{badge.id}/swap_code", headers: auth_headers(owner)
    assert_response :unprocessable_entity
    assert_match "not transferable", json_response["error"]
  end

  test "swap exchanges owner_ids between two badges via a swap token" do
    creator = create_user
    ownerA = create_user
    ownerB = create_user
    bc = create_badge_class(creator: creator, transferable: true)
    badgeA = create_badge(badge_class: bc, creator: creator, owner: ownerA)
    badgeB = create_badge(badge_class: bc, creator: creator, owner: ownerB)

    post "/api/v1/badges/#{badgeA.id}/swap_code", headers: auth_headers(ownerA)
    token = json_response["token"]

    post "/api/v1/badges/#{badgeB.id}/swap", params: { swap_token: token }, headers: auth_headers(ownerB)
    assert_response :success

    assert_equal ownerB.id, badgeA.reload.owner_id
    assert_equal ownerA.id, badgeB.reload.owner_id
  end

  test "swap requires the caller to own the badge they're calling swap on" do
    creator = create_user
    ownerA = create_user
    ownerB = create_user
    outsider = create_user
    bc = create_badge_class(creator: creator, transferable: true)
    badgeA = create_badge(badge_class: bc, creator: creator, owner: ownerA)
    badgeB = create_badge(badge_class: bc, creator: creator, owner: ownerB)

    post "/api/v1/badges/#{badgeA.id}/swap_code", headers: auth_headers(ownerA)
    token = json_response["token"]

    post "/api/v1/badges/#{badgeB.id}/swap", params: { swap_token: token }, headers: auth_headers(outsider)
    assert_response :forbidden
  end

  test "swap fails if the target badge (the one the token was generated from) is no longer transferable" do
    # swap_code itself requires transferable: true to issue a token, so the only way
    # target_badge ends up non-transferable at /swap time is if the badge_class is
    # toggled after the token was already issued (tokens are JWTs, valid for 30 days).
    # The target uses its own badge_class so the caller's badge stays transferable.
    creator = create_user
    ownerA = create_user
    ownerB = create_user
    bcA = create_badge_class(creator: creator, transferable: true)
    bcB = create_badge_class(creator: creator, transferable: true)
    badgeA = create_badge(badge_class: bcA, creator: creator, owner: ownerA)
    badgeB = create_badge(badge_class: bcB, creator: creator, owner: ownerB)

    post "/api/v1/badges/#{badgeA.id}/swap_code", headers: auth_headers(ownerA)
    token = json_response["token"]

    bcA.update!(transferable: false)

    post "/api/v1/badges/#{badgeB.id}/swap", params: { swap_token: token }, headers: auth_headers(ownerB)
    assert_response :unprocessable_entity
    assert_match "target badge is not transferable", json_response["error"]
    assert_equal ownerA.id, badgeA.reload.owner_id
    assert_equal ownerB.id, badgeB.reload.owner_id
  end

  test "swap rejects when the CALLER's own badge is burned (self-guard)" do
    creator = create_user
    ownerA = create_user
    ownerB = create_user
    bc = create_badge_class(creator: creator, transferable: true)
    badgeA = create_badge(badge_class: bc, creator: creator, owner: ownerA)
    badgeB = create_badge(badge_class: bc, creator: creator, owner: ownerB)

    post "/api/v1/badges/#{badgeA.id}/swap_code", headers: auth_headers(ownerA)
    token = json_response["token"]

    badgeB.update!(status: "burned") # caller's badge is no longer live

    post "/api/v1/badges/#{badgeB.id}/swap", params: { swap_token: token }, headers: auth_headers(ownerB)
    assert_response :unprocessable_entity
    assert_match "badge is not owned/accepted", json_response["error"]
    assert_equal ownerA.id, badgeA.reload.owner_id # nothing moved
  end

  test "swap fails if the target badge (the one the token was generated from) is no longer minted/accepted" do
    # Same reasoning: swap_code requires minted/accepted to issue a token, so the target
    # badge can only be burned *after* the token was already generated.
    creator = create_user
    ownerA = create_user
    ownerB = create_user
    bc = create_badge_class(creator: creator, transferable: true)
    badgeA = create_badge(badge_class: bc, creator: creator, owner: ownerA)
    badgeB = create_badge(badge_class: bc, creator: creator, owner: ownerB)

    post "/api/v1/badges/#{badgeA.id}/swap_code", headers: auth_headers(ownerA)
    token = json_response["token"]

    badgeA.update!(status: "burned")

    post "/api/v1/badges/#{badgeB.id}/swap", params: { swap_token: token }, headers: auth_headers(ownerB)
    assert_response :unprocessable_entity
    assert_match "target badge is not owned/accepted", json_response["error"]
  end

  test "swap rejects an invalid swap token" do
    creator = create_user
    owner = create_user
    bc = create_badge_class(creator: creator, transferable: true)
    badge = create_badge(badge_class: bc, creator: creator, owner: owner)

    post "/api/v1/badges/#{badge.id}/swap", params: { swap_token: "not-a-real-token" }, headers: auth_headers(owner)
    assert_response :unprocessable_entity
    assert_match "invalid swap token", json_response["error"]
  end

  test "swap rejects a token that was not minted as a swap code" do
    creator = create_user
    owner = create_user
    other = create_user
    bc = create_badge_class(creator: creator, transferable: true)
    badge = create_badge(badge_class: bc, creator: creator, owner: owner)
    # A normal auth token is a valid JWT but carries no swap auth_type.
    forged = "Bearer #{JwtService.encode({ 'badge_id' => badge.id })}".split.last

    post "/api/v1/badges/#{badge.id}/swap", params: { swap_token: forged }, headers: auth_headers(owner)
    assert_response :unprocessable_entity
    assert_match "invalid swap token", json_response["error"]
  end

  test "update rejects an invalid display with 422 (not a 500)" do
    creator = create_user
    owner = create_user
    bc = create_badge_class(creator: creator)
    badge = create_badge(badge_class: bc, creator: creator, owner: owner)

    patch "/api/v1/badges/#{badge.id}", params: { display: "sideways" }, headers: auth_headers(owner)
    assert_response :unprocessable_entity
    assert_match "invalid display", json_response["error"]
  end

  test "a not-found badge yields a JSON 404 (base-controller rescue_from)" do
    user = create_user
    post "/api/v1/badges/does-not-exist/burn", headers: auth_headers(user)
    assert_response :not_found
    assert_equal "Not found", json_response["error"]
  end
end
