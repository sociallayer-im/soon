# Existing behavior suites isolate the external content gateway. The dedicated
# safety service/gate suites exercise rejection, outage and persistence order.
module ContentSafetyTestGateway
  def run
    WechatContentSafety.stub(:check!, true) do
      ContentImageReferences.stub(:check!, true) { super }
    end
  end
end

module ImageSafetyTestGateway
  def run
    WechatContentSafety.stub(:check_image!, true) { super }
  end
end
