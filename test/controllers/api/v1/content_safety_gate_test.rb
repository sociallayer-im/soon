require "test_helper"

class Api::V1::ContentSafetyGateTest < ActionDispatch::IntegrationTest
  test "unchecked comment images cannot bypass upload endpoint" do
    user = create_user
    WechatContentSafety.stub(:check!, true) do
      assert_no_difference "Comment.count" do
        post "/api/v1/comments", params: {comment: {comment_type: "comment", content: "![x](https://example.com/bypass.png)"}}, headers: auth_headers(user)
      end
      assert_response :unprocessable_entity
      assert_includes response.body, "重新上传图片"
    end
  end

  test "unsafe comments are rejected before persistence" do
    user = create_user
    WechatContentSafety.stub(:check!, ->(**_) { raise WechatContentSafety::Rejected }) do
      assert_no_difference "Comment.count" do
        post "/api/v1/comments", params: {comment: {comment_type: "comment", content: "unsafe"}}, headers: auth_headers(user)
      end
      assert_response :unprocessable_entity
      assert_includes response.body, "违规信息"
    end
  end

  test "gateway outage does not publish unchecked comments" do
    user = create_user
    WechatContentSafety.stub(:check!, ->(**_) { raise WechatContentSafety::Unavailable }) do
      assert_no_difference "Comment.count" do
        post "/api/v1/comments", params: {comment: {comment_type: "comment", content: "text"}}, headers: auth_headers(user)
      end
      assert_response :service_unavailable
    end
  end
end
