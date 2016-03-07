function [uni]=UQI(real,res)

%Calculate universal quality index (UQI)to evaluate the degree of
%similarity between the reconstructed and phantom images for chosen ROIs.

%Its value ranges from zero to one. A UQI value closer to one suggests
%better similarity to true image.


%Ref: Few-view cone-beam CT reconstruction with deformed prior image
%doi: 10.1118/1.4901265

%real = exact phantom
%res = reconstructed image
real=real(:);
res=res(:);

N=length(real);

%Mean
meanreal=mean(real);
meanres=mean(res);


%Variance
% varreal=sum((real-meanreal)^2)/(N-1);
varreal=var(real);
varres=var(res);


%Covariance
cova=sum((res-meanres).*(real-meanreal))/(N-1);
% cova=cov(real,res);

front= (2*cova)/(varres^2+varreal^2);
back= (2*meanres*meanreal)/(meanres^2+meanreal^2);

% uni= ((2*cova)/((varres^2)+(varreal^2)))*((2*meanres*meanreal)/(((meanres^2)+(meanreal^2))));
uni=front*back;





end