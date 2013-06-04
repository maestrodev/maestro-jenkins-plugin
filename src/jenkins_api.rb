module Jenkins
  module Api

    @error
    def self.error
      @error
    end

    def self.show_me_the_error(response)
      require "hpricot"
      doc = Hpricot(response.body)
      error_msg = doc.search("td#main-panel p")
      unless error_msg.inner_text.blank?
        @error = error_msg.inner_text
      else
        # TODO - what are the errors we get?
        @error = "#{response.code} #{response.body}"
      end
      Maestro.log.warn "Jenkins Error: #{@error}"
    end
  end
end
